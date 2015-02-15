###

dnschain
http://dnschain.org

Copyright (c) 2014 okTurtles Foundation

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

###

###
This file contains the logic to handle connections on port 443
These connections can be naked HTTPS or wrapped inside of TLS
###

###
            __________________________        ________________________
443 traffic |                        |   *--->|      TLSServer       |     ______________
----------->|     EncryptedServer    |--*     | (Dumb decrypter)     |---->| HTTPServer |----> Multiple destinations
            |(Categorization/Routing)|   *    | (One of many)        |     ______________
            __________________________    *   | (Unique destination) |
                                           *  _______________________|
                                            *    _____________   Soon
                                             *-->| TLSServer |----------> Unblock (Vastly simplified)
                                                 _____________
###

module.exports = (dnschain) ->
    # expose these into our namespace
    for k of dnschain.globals
        eval "var #{k} = dnschain.globals.#{k};"

    libHTTPS = new ((require "./httpsUtils")(dnschain)) # TODO: httpsUtils doesn't need to be a class
    pem = (require './pem')(dnschain)
    httpSettings = gConf.get "http"
    unblockSettings = gConf.get "unblock"
    tlsLog = gNewLogger "TLSServer"

    keyMaterial = _(httpSettings).pick(['tlsKey', 'tlsCert']).transform((o, v, k)->
        o[k] = { key:k, path:v, exists: fs.existsSync(v) }
    ).value()

    # Auto-generate public/private key pair if they don't exist
    if _.some(keyMaterial, exists:false)
        missing = _.find(keyMaterial, exists:false)
        tlsLog.warn "File for http:#{missing.key} does not exist: #{missing.path}".bold.red
        tlsLog.warn "Vist this link for information on how to generate this file:".bold
        tlsLog.warn "https://github.com/okTurtles/dnschain/blob/master/docs/How-do-I-run-my-own.md#getting-started".bold

        # In the case where one file exists but the other does not
        # we do not auto-generate them for the user (so as to not overwrite anything)      
        if exists = _.find(keyMaterial, exists:true)
            tlsLog.error "\nhttp:#{exists.key} exists at:\n\t".bold.yellow, exists.path.bold, "\nbut http:#{missing.key} does not exist at:\n\t".bold.red, missing.path.bold
            gErr "Missing file for http:#{missing.key}"

        # TODO: make async generation work with running TLSServer asynchronously
        tlsLog.warn "\nAuto-generating private key and certificate for you...".bold.yellow
        
        {tlsKey, tlsCert} = gConf.chains.dnschain.stores.defaults.get('http')
        unless httpSettings.tlsKey is tlsKey and httpSettings.tlsCert is tlsCert
            gErr "Can't autogen keys for you because you've customized their paths"

        pem.genKeyCertPair httpSettings.tlsKey, httpSettings.tlsCert, (err) ->
            throw err if err
            tlsLog.info "Successfully autogenerated", {key:tlsKey, cert:tlsCert}

    tlsOptions =
        key: fs.readFileSync httpSettings.tlsKey
        cert: fs.readFileSync httpSettings.tlsCert

    # Fetch the public key fingerprint of the cert we're using and log to console 
    fingerprint = ""
    pem.certFingerprint (err, f) ->
        throw err if err
        tlsLog.info "Your certificate fingerprint is:", (fingerprint = f).bold

    TLSServer = tls.createServer tlsOptions, (c) ->
        libHTTPS.getStream "127.0.0.1", httpSettings.port, (err, stream) ->
            if err?
                tlsLog.error gLineInfo "Tunnel failed: Could not connect to HTTP Server"
                c?.destroy()
                return stream?.destroy()
            c.pipe(stream).pipe(c)
    TLSServer.on "error", (err) -> tlsLog.error err
    TLSServer.listen httpSettings.internalTLSPort, "127.0.0.1", -> tlsLog.info "Listening"

    class EncryptedServer
        constructor: (@dnschain) ->
            @log = gNewLogger "HTTPS"
            @log.debug gLineInfo "Loading HTTPS..."
            @rateLimiting = gConf.get 'rateLimiting:https'

            @server = net.createServer (c) =>
                key = "https-#{c.remoteAddress}"
                limiter = gThrottle key, => new Bottleneck @rateLimiting.maxConcurrent, @rateLimiting.minTime, @rateLimiting.highWater, @rateLimiting.strategy
                limiter.submit (@callback.bind @), c, null
            @server.on "error", (err) -> gErr err
            @server.on "close", => @log.info "HTTPS server has shutdown."
            gFillWithRunningChecks @

        start: ->
            @startCheck (cb) =>
                @server.listen httpSettings.tlsPort, httpSettings.host, =>
                    cb httpSettings

        shutdown: ->
            @shutdownCheck (cb) =>
                TLSServer.close() # node docs don't indicate this takes a callback
                @server.close cb

        callback: (c, cb) ->
            libHTTPS.getClientHello c, (err, category, host, buf) =>
                @log.debug err, category, host, buf?.length
                if err?
                    @log.debug gLineInfo "TCP handling: "+err.message
                    cb()
                    return c?.destroy()

                # UNBLOCK: Check if needs to be hijacked

                isRouted = false # unblockSettings.enabled and unblockSettings.routeDomains[host]?
                isDNSChain = (
                    (category == libHTTPS.categories.NO_SNI) or
                    ((not unblockSettings.enabled) and category == libHTTPS.categories.SNI) or
                    (unblockSettings.enabled and (host in unblockSettings.acceptApiCallsTo)) or
                    ((host?.split(".")[-1..][0]) == "dns")
                )
                isUnblock = false

                [destination, port, error] = if isRouted
                    ["127.0.0.1", unblockSettings.routeDomains[host], false]
                else if isDNSChain
                    ["127.0.0.1", httpSettings.internalTLSPort, false]
                else if isUnblock
                    [host, 443, false]
                else
                    ["", -1, true]

                if error
                    @log.error "Illegal domain (#{host})"
                    cb()
                    return c?.destroy()

                libHTTPS.getStream destination, port, (err, stream) =>
                    if err?
                        @log.error gLineInfo "Tunnel failed: Could not connect to internal TLS Server"
                        c?.destroy()
                        cb()
                        return stream?.destroy()
                    stream.write buf
                    c.pipe(stream).pipe(c)
                    c.resume()
                    @log.debug gLineInfo "Tunnel: #{host}"
                    cb()

        getFingerprint: ->
            if fingerprint.length == 0
                gErr "Cached fingerprint couldn't be read in time."
            else
                fingerprint
