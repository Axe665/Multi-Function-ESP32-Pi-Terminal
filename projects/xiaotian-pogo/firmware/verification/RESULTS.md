# v2.1.0 / QML 0.1.0 验证记录

2026-11-18。本轮只刷用户明确确认的新红外模块，未操作桥板固件。

| 检查 | 结果 |
|---|---|
| ESP身份 | ESP32-S3 rev0.2，内置8MB PSRAM，MAC d8:85:ac:d6:1d:c0，COM23 |
| ESP构建 | ESP-IDF构建通过，app 967632字节，factory 3MB，DIO16MB40MHz；PSRAM未启用 |
| 烧录 | 三段 Hash of data verified，见 v21-flash.log |
| 首次USB状态 | version2.1.0，enabled=false，stable=-1，pogo.ready=true，wired=false，rx_frames=0 |
| USB启停 | 两轮enable/disable成功，enable后stable=1（只证明输入高电平）；见 v21-usb.json |
| 个人记录 | record_stop不停止采样；停止续租约5.2秒后结束记录，enabled仍true |
| 最终状态 | 真机UI检查结束回到待机，无个人记录 |
| 原生C | 滤波、初始/变化、会话归属、租约、清缓存、64事件环、启停/重启测试通过 |
| Python | 12项unittest通过：6项TLS/会话客户端、6项终端控制状态 |
| QML构建 | 本机Qt6.10.1/MinGW，CMake+Ninja通过 |
| QML演示 | 离屏加载、触点分离不停止监测、遮挡变化、退出记录、待机后启用按钮可用检查通过 |
| 真机到QML | COM23→Python worker→Qt backend→QML status，enable与disable通过，结束待机 |
| 预览 | 根目录panel-preview.png已渲染检查；显式演示数据，不是真机光路证据 |
| 桥板候选 | 生成差异与完整候选，原工程未改；没有编译/烧录/实板验证 |

未验证：焊接后真实pogo握手和拔插恢复、光束遮挡闭环、Wi-Fi HTTPS互通/掉线恢复、树莓派本机编译和QML显示、现有终端插件路由、真实账号与云上传。

本轮没有以“上拉读到1”冒充“红外光路已验收”，也没有把ready=true冒充握手成功。现场需按根目录手册继续做。

新增代码保存于独立目录，旧v2快照不变。未进行Git提交/推送或远端部署。设备配对文件在本机.private，排除在公开交付包之外。
