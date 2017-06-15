qs = require 'qs'


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
    app._pages ?= {}
    app.Page.prototype.setClass = (cls) ->
        if @__proto__
            @__proto__ = cls::
        else
            for k, v of cls::
                if v and @[k] != v
                    @[k] = v

    app.on 'ready', (page) ->
        ns = page.model.get '$render.ns'
        if ns of app._pages
            page.setClass app._pages[ns]
            page.preRender()

    app.on 'render', (page) ->
        page.preRender()
        
    app.on 'load', (page) -> page.emit 'create'
    app.on 'routeDone', (page) ->
        if not app.derby.util.isServer
            page.emit 'create'

    app.controller = (cls) ->
        if cls.prototype not instanceof PageController
            oldPrototype = cls::
            cls:: = new PageController
            for k, v of oldPrototype
                cls::[k] = v

        controller = (page, model, params, next) ->
            @setClass cls

            if @$defaultQuery and not Object.keys(@params.query).length
                model.set '$render.params.query', @$defaultQuery()

            for path, handler of @$params or {}
                path = "$render.params.#{path}"
                if typeof handler == 'string'
                    handler = @$paramTypes[handler]
                model.setDiff path, handler.call @, model.get path

            model.set '_ownRefs', []
            @$subscribe @$model, (err) =>
    #            return next() if err == 404
                return next err if err
                @$render next


        if cls::path
            paths =
                if typeof cls::path == 'string'
                    [ cls::path ]
                else
                    cls::path
            for path in paths
                app.get path, controller
                if cls::handlePost
                    app.post path, controller

            if app.tracksRoutes
                app.tracksRoutes.sort (a, b) ->
                    compareRoutes a[1], b[1]
            else
                app.history.routes.queue.get.sort (a, b) ->
                    compareRoutes a.path, b.path


        if cls::view
#            app.component cls
            app.loadViews cls::view, cls::name

        if cls::name
            app._pages[cls::name] = cls

        if cls::register
            cls::register app


    app.PageController = class PageController extends app.Page
        constructor: ->
        $paramTypes:
            date: (v) -> if v then new Date v
            number: (v) -> if v then Number v
            boolean: (v) -> v == 'true'
    
        $subscribe: ($model, next) ->
            return next() if not $model
            if typeof $model == 'function'
                return @$subscribe $model.call(@), next
            if Array.isArray $model
                return next() if not $model.length
                return @$subscribe $model[0], (err) =>
                    return next err if err
                    @$subscribe $model[1..], next
    
            subscriptions = []
            refs = {}
            for name, query of $model
                $wrapper = @model.at name
                if typeof query == 'object' and '$required' of query
                    @model.push '$required', name
    
                if query == undefined
                else if typeof query == 'string'
                    refs[name] = @model.root.at query
                    if '.' in query
                        subscriptions.push query
                    else
                        subscriptions.push @model.root.query query, {}
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
#                else if '$sort' of query
#                    @model.root.sort(query.$collection, query.$sort).ref $wrapper
                else if '$ref' of query
                    refs[name] = query.$ref
                else if '$start' of query
                    @model.start $wrapper, query.$start...
                else if '$ids' of query
                    @model.push '_pathQueries', query
                    ids = @model.get query.$ids
                    for id in ids or []
                        subscriptions.push query.$collection + '.' + id
                else
                    if '$ids' of query
                        $wrapper = @model.root.query query.$collection, '_page.' + query.$ids
                    else if '$serverQuery' of query
                        params = Object.assign {}, query
                        delete params.$collection
                        delete params.$serverQuery
                        $wrapper = @model.root.serverQuery \
                            query.$collection,
                            query.$serverQuery,
                            params
                    else
                        params = Object.assign {}, query
                        delete params.$collection
                        $wrapper = @model.root.query \
                            query.$collection,
                            params
    
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
                    if not @[name].get()
                        return next 404
                next()
    
        $render: (next) ->
            return next() unless @name
        
            if @static
                @page.renderStatic @name
            else
                @page.render @name
    
    
        preRender: (model) ->
            for name of @model.get()
                @[name] = @model.at name

            for {path, hash} in @model.get('_queries') or []
                @[path] = @model.root._queries.map[hash]

            @model.get('_pathQueries')?.forEach (q) =>
                @model.on 'change', q.$ids, (value, oldValue) =>
                    if value
                        @model.root.subscribe value.map (id) -> q.$collection + '.' + id
                    if oldValue
                        @model.root.unsubscribe oldValue.map (id) -> q.$collection + '.' + id

                @model.on 'change', q.$ids + '.*', (index, value, oldValue) =>
                    if value
                        @model.root.subscribe q.$collection + '.' + value
                    if oldValue
                        @model.root.unsubscribe q.$collection + '.' + oldValue

                @model.on 'insert', q.$ids, (index, values) =>
                    @model.root.subscribe values.map (id) -> q.$collection + '.' + id

                @model.on 'remove', q.$ids, (index, values) =>
                    @model.root.unsubscribe values.map (id) -> q.$collection + '.' + id

            for name in @root.get('_page.$required') or []
                @model.on 'change', name, (value) =>
                    if not value
                        @app.history.refresh()
    
            @init?(model)
    
    
            @on 'create', ->
                @model.on 'change', '$render.params.query**', (path) =>
                    #return if String(arguments[1]) == String(arguments[2])  # Временный костыль.
                    # Не пашет для объектов
                    return if path.startsWith '_'
                    query = @model.get '$render.params.query'
                    query = JSON.parse JSON.stringify query
                    for k of query
                        if k.startsWith '_'
                            delete query[k]
                    queryString = qs.stringify query
                    rerender = not @onQueryChange? or @onQueryChange == 'rerender'
                    @app.history.replace '?' + queryString, rerender
                    if @onQueryChange == 'resubscribe'
                        @model.root.set '_session.loading', true
                        # TODO: unsubscribe path queries
                        oldSubscriptions = {}
                        for q in @model.get '_queries'
                            if @model.get('_ownRefs').includes q.path
                                oldSubscriptions[q.path] = @[q.path]
                        oldRefs = @model.get '_ownRefs'
                        @model.set '_ownRefs', []
                        @$subscribe @$model, (err) =>
                            for path in oldRefs
                                if not @model.get('_ownRefs').includes path
                                    @model.removeRef path
                            for name, query of oldSubscriptions
                                query.unsubscribe()
                            @model.root.set '_session.loading', false
