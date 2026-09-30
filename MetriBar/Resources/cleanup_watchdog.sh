#!/bin/bash
# MetriBar 孤儿清理哨兵：App主进程不在时，清掉残留下载/服务/安装进程
if pgrep -f "MetriBar.app/Contents/MacOS/MetriBar" >/dev/null; then exit 0; fi
pkill -f "curl.*modelscope\.cn/models/" 2>/dev/null
pkill -f "Application Support/MetriBar/env.*mlx_lm.server" 2>/dev/null
pkill -f "Application Support/MetriBar/env.*pip install" 2>/dev/null
exit 0
