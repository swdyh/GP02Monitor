var express = require('express')
var app = express.createServer(express.logger(), express.bodyParser())

var status = 'connected'
var codes = {
    'connecting': '900',
    'connected': '901',
    'disconnected': '902',
    'disconnecting': '3'
}
app.get('/', function(req, res) {
    res.send('GP02 Cheker Test Server')
})
app.get('/api/monitoring/status', function(req, res) {
    var r = ['<?xml version="1.0" encoding="utf-8" ?>',
             '<res>',
             '<ConnectionStatus>' + codes[status] +'</ConnectionStatus>',
             '</res>'].join('\n')
    res.send(r)
})
app.post('/api/dialup/dial', function(req, res) {
    var re = /<Action>(\d)<\/Action>/
    var m = req.rawBody.match(re)
    if (m[1] == '0') {
        status = 'disconnecting'
        setTimeout(function() { status = 'disconnected' }, 3000)
    }
    else if (m[1] == '1') {
        status = 'connecting'
        setTimeout(function() { status = 'connected' }, 3000)
    }
    res.send('ok')
})
app.listen(8001)

setInterval(function() {
    status = 'disconnected'
}, 20 * 1000)
