#!/usr/bin/lua

require 'std'
local appctl = require 'appctl'

appctl.APPNAME = 'frpc'
appctl.HELP = help

if #arg > 0 then
	appctl.dispatch(arg)
else
	appctl.interact()
end
