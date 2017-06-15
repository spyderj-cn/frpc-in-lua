# frpc-in-lua

用lua重新实现的[frp](https://github.com/fatedier/frp)客户端。

frpc-in-lua主要解决了go-lang编译后的可执行文件尺寸太大， 无法放入各类智能硬件固件的问题。
frpc-in-lua本身只需30KB左右，但是依赖lua和[lask](https://github.com/spyderj-cn/lask)，
后两者大概需要500KB左右，其中lua约200KB， lask约300KB。

frpc-in-lua当前对应frp v0.9.3，且暂不支持：
* udp tunnel
* 转发加密
* 通过http proxy连接frps

但也提供了额外的功能：
* 为了能与您的配置系统融合，ini中支持类似shell函数求值的写法， 例如： server_addr=$(uci get myconfig.frpc.server_addr)
* frpctl.lua可用于动态的添加/删除/查看一个代理项，此工具不是必须的

使用方式:  lua frpc.lua -c frpc.ini

更多信息请使用: lua frpc.lua -h

开发者：上海高恪网络
