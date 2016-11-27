path = require 'path'

_ = require 'lodash'
qs = require 'qs'

Component = require('derby').Component


compareRoutes = (a, b) ->
    if a == b
        0
    else if a == '*'
        -1
    else if b == '*'
        1
    else if a > b
        -1
    else
        1
        
        
module.exports = (app) ->
    app.controller = (cls) ->
        if cls.prototype not instanceof PageComponent
            oldPrototype = cls::
            cls:: = new PageComponent()
            cls::_init = oldPrototype.init
            delete oldPrototype.init
            _.extend cls::, oldPrototype

        controller = (page, model, params, next) ->
            model = model.scope '_page'
            model.ref 'params', model.root.at '$render.params'

            context = page._controllerContext ?= app: page.app, model: model, page: page
            context.params = model.get 'params'
            context.__proto__ = cls::

            if context.$defaultQuery and _.isEmpty context.params.query
                model.set 'params.query', context.$defaultQuery()

            for path, handler of context.$params or {}
                path = "params.#{path}"
                if _.isString handler
                    handler = context.$paramTypes[handler]
                model.setDiff path, handler.call context, model.get path

            model.set '_ownRefs', []
            context.$subscribe context.$model, (err) ->
    #            return next() if err == 404
                return next err if err
                context.$render next


        if cls::path
            app.get cls::path, controller

            if app.tracksRoutes
                app.tracksRoutes.sort (a, b) ->
                    compareRoutes a[1], b[1]
            else
                app.history.routes.queue.get.sort (a, b) ->
                    compareRoutes a.path, b.path


        if cls::name
            app.component cls

        if cls::register
            cls::register app


module.exports.PageComponent = class PageComponent extends Component
    $paramTypes:
        number: (v) -> if v then Number v
        boolean: (v) -> v == true

    $subscribe: ($model, next) ->
        return next() if not $model
        if typeof $model == 'function'
            return @$subscribe $model.call(@), next
        if Array.isArray $model
            return next() if _.isEmpty $model
            return @$subscribe $model[0], (err) =>
                return next err if err
                @$subscribe $model[1..], next

        subscriptions = []
        refs = {}
        for name, query of $model
            query = _.clone query
            $wrapper = @model.at name
            if _.isObject(query) and '$required' of query
                @model.push '$required', name

            if query == undefined
            else if typeof query == 'string'
                refs[name] = @model.root.at query
                subscriptions.push query
            else if '$path' of query
                refs[name] = @model.root.at query.$path
                subscriptions.push query.$path
            else if '$copy' of query
                copy = @model.getDeepCopy query.$copy
                $wrapper.set copy
            else if '$set' of query
                $wrapper.set query.$set
            else if '$setNull' of query
                $wrapper.setNull query.$setNull
            else if '$filter' of query
                q = @model.root.filter query.$collection, query.$filter
                if '$sort' of query
                    q = q.sort query.$sort
                q.ref $wrapper
            else if '$sort' of query
                @model.root.sort(query.$collection, query.$sort).ref $wrapper
            else if '$ref' of query
                refs[name] = query.$ref
            else if '$start' of query
                @model.start $wrapper, query.$start...
            else
                if '$ids' of query
                    $wrapper = @model.root.query query.$collection, '_page.' + query.$ids
                else if '$serverQuery' of query
                    $wrapper = @model.root.serverQuery \
                        query.$collection,
                        query.$serverQuery,
                        _.omit query, '$collection', '$serverQuery'
                else
                    $wrapper = @model.root.query \
                        query.$collection,
                        _.omit query, '$collection'

                @model.push '_queries', path: name, hash: $wrapper.hash
                refs[name] = $wrapper
                subscriptions.push $wrapper

            @[name] = $wrapper

        @model.root.subscribe subscriptions, (err) =>
            return next err if err
            for name, query of refs
                rootPath = '_page.' + name
                # Remove previous ref when resubscribing. Remove only when ref changes to refList and vice versa.
                if query.expression?.$distinct or query.expression?.$count or query.expression?.$aggregate
                    if rootPath of @model.root._refLists.fromMap
                        @model.removeRef name
                    query.refExtra @model.at name
                else
                    if query.expression
                        if rootPath of @model.root._refs.fromMap
                            @model.removeRef name
                    else
                        if rootPath of @model.root._refLists.fromMap
                            @model.removeRef name
                    @model.ref name, query

                @model.push '_ownRefs', name

            for name in @model.get('$required') or []
                if _.isEmpty @[name].get()
                    return next 404
            next()

    $render: (next) ->
        return next() unless @name
    
        if @static
            @page.renderStatic @name
        else
            @page.render @name


    init: (model) ->
        @_events = _.clone @_events
        @page.main = @
        @_scope = ['_page']
        @model = @model.scope '_page'
        @model.data = @model.get()
        @root = @model.root

        for name of @model.get()
            @[name] = @model.at name

        for {path, hash} in @model.get('_queries') or []
            @[path] = @root._queries.map[hash]

        @params = @page.params

        for name in @root.get('_page.$required') or []
            @model.on 'change', name, (value) =>
                if not value
                    @app.history.refresh()

        @_init?(model)


        @on 'create', ->
            @model.on 'change', 'params.query**', (path) =>
                #return if String(arguments[1]) == String(arguments[2])  # Временный костыль.
                # Не пашет для объектов
                return if _.startsWith path, '_'
                query = @model.get 'params.query'
                query = _.omitBy query, (v, k) -> _.startsWith k, '_'
                @app.history.replace '?' + qs.stringify(query), not @onQueryChange? or @onQueryChange == 'rerender'
                if @onQueryChange == 'resubscribe'
                    @model.root.set '_session.loading', true
                    # TODO: unsubscribe path queries
                    oldSubscriptions = _.pick @, _.map @model.get('_queries'), 'path'
                    oldSubscriptions = _.pick oldSubscriptions, @model.get '_ownRefs'
                    oldRefs = @model.get '_ownRefs'
                    @model.set '_ownRefs', []
                    @$subscribe @$model, (err) =>
                        for path in oldRefs
                            if not _.includes @model.get('_ownRefs'), path
                                @model.removeRef path
                        for name, query of oldSubscriptions
                            query.unsubscribe()
                        @model.root.set '_session.loading', false