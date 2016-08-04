path = require 'path'

_ = require 'lodash'
qs = require 'qs'



setQueries = (obj, queries, map) ->
    for name, hash of queries
        if _.isObject hash
            obj[name] = {}
            setQueries obj[name], hash, map, name + '.'
        else
            obj[name] = map[hash]


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
        registerController app, cls


registerController = (app, cls) ->
    _init = cls::init
    cls::init = ->
        @page.main = @
        @_scope = ['_page']
        @model = @model.scope '_page'
        @model.data = @model.get()
        @root = @model.root

        for name of @model.get()
            @[name] = @model.at name

        setQueries @, @root.get('_page.$queries'), @root._queries.map

        @params = @page.params

        for name in @root.get('_page.$required') or []
            @model.on 'change', name, (value) =>
                if not value
                    @app.history.refresh()

        _init.call this if _init


    _create = cls::create
    cls::create = ->
        _create.call this if _create

        @model.on 'change', 'params.query**', (path) =>
            #return if String(arguments[1]) == String(arguments[2])  # Временный костыль.
            # Не пашет для объектов
            return if _.startsWith path, '_'
            query = @model.get 'params.query'
            query = _.omitBy query, (v, k) -> _.startsWith k, '_'
            app.history.replace '?' + qs.stringify(query), not @onQueryChange? or @onQueryChange == 'rerender'
            if @onQueryChange == 'resubscribe'
                @model.root.set '_session.loading', true
                # TODO: unsubscribe path queries
                oldSubscriptions = _.pick @, _.keys @model.get '$queries'
                @subscribe @$model, (err) =>
                    for name, query of oldSubscriptions
                        if query != @[name]
                            query.unsubscribe()
                    # При переподписке не требуется. @subscribe и так всё присвоит
#                    setQueries @, @root.get('_page.$queries'), @root._queries.map
                    @model.root.set '_session.loading', false


    cls::subscribe = ($model, next) ->
        return next() if not $model
        if typeof $model == 'function'
            return @subscribe $model.call(@), next
        if Array.isArray $model
            return next() if _.isEmpty $model
            return @subscribe $model[0], (err) =>
                return next err if err
                @subscribe $model[1..], next

        subscriptions = []
        refs = {}
        for name, query of $model
            query = _.clone query
            $name = @model.at name
            if _.isObject(query) and '$required' of query
                @model.push '$required', name

            if query == undefined
                $name.set query
                q = $name
            else if typeof query == 'string'
                q = @model.ref $name, @model.root.at query
#                    if query.match /^[a-zA-Z]/
                subscriptions.push query
            else if '$path' of query
                q = @model.ref $name, @model.root.at query.$path
                subscriptions.push query.$path
            else if '$copy' of query
                copy = @model.getDeepCopy query.$copy
                if '$pick' of query
                    copy = _.pick copy, query.$pick
                if '$omit' of query
                    copy = _.omit copy, query.$omit
                if '$parse' of query
                    copy = query.$parse copy
                $name.set copy
            else if '$set' of query
                $name.set query.$set
                q = $name
            else if '$setNull' of query
                $name.setNull query.$setNull
                q = $name
            else if '$filter' of query
                q = @model.root.filter query.$collection, query.$filter
                if '$sort' of query
                    q = q.sort query.$sort
                q = q.ref $name
            else if '$sort' of query
                q = @model.root.sort(query.$collection, query.$sort).ref $name
            else if '$ref' of query
                refs[name] = query
                q = $name
            else if '$start' of query
                q = @model.start $name, query.$start...
            else
                if '$ids' of query
                    q = @model.root.query query.$collection, '_page.' + query.$ids
                else if '$serverQuery' of query
                    q = @model.root.serverQuery \
                        query.$collection,
                        query.$serverQuery,
                        _.omit query, '$collection', '$serverQuery'
                else
                    q = @model.root.query \
                        query.$collection,
                        _.omit query, '$collection'

                @model.set '$queries.' + name, q.hash
                refs[name] = q
                subscriptions.push q
#                    if query.$distinct or query.$count
#                        q.refExtra $name
#                    else
#                        @model.ref $name, q

            @[name] = q

        @model.root.subscribe subscriptions, (err) =>
            return next err if err
            for name, query of refs
                if query.$ref
                    @model.ref name, query.$ref
                else if query.expression.$distinct or query.expression.$count or query.expression.$aggregate
                    query.refExtra @model.at name
                else
                    @model.ref name, query

            for name in @model.get('$required') or []
                if _.isEmpty @[name].get()
                    return next 404
            next()


    if _.isString cls::path
        cls::path = [cls::path]

    controller = (page, model, params, next) ->
        model = model.at '_page'
        model.ref 'params', model.root.at '$render.params'
        for name, func of cls::$params or {}
            path = "params.#{name}"
            if model.get(path)?
                model.setDiff path, func model.get path

        # Create PageComponent object to make subscriptions
        context = page._controllerContext ?= model: model
        context.params = model.get 'params'
        context.__proto__ = cls::

        context.subscribe context.$model, (err) ->
#            return next() if err == 404
            return next err if err

            return next() unless context.name

            if context.static
                page.renderStatic context.name
            else
                page.render context.name

    for p in cls::path or []
        app.get p, controller
        
        
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
