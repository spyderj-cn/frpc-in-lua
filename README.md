# frpc-in-lua

[README](README.md) | [中文](README_zh.md)

This is the client of [frp](https://github.com/fatedier/frp)(0.9.3) implemented in Lua.

We made it because the executable file compiled by go-lang is too huge to be put
into firmware of smart devices. However, since we program it in Lua, you need the
Lua interpreter. And, it also depends on [lask](https://github.com/spyderj-cn/lask), 
which provides an async I/O communication framework. Together they require about 500 kilobytes.

So far not all functionalities are supported, as listed below:
* udp tunnel
* encryption
* connect frps by http proxy

Usage:
lua frpc.lua -c /etc/frpc.ini

For more help, use 'lua frpc.lua -h'.
