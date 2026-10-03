# 下一步验证

v0.3 已达到可持久保存的源码检查点，不是已完成手机控制产品。

1. 确认实际开发板模块、USB-C/USB OTG接线、VBUS/CC供电与iPhone配置值；保持默认USB关闭
2. 在获授权的测试手机上按阶段验证真实Host枚举、rawmux、QueryType，记录错误但不记录私密材料
3. 单独设计并批准合法信任/配对与设备端身份配置流程；不要在聊天/归档导出私钥或配对记录
4. 验证DeviceCertificate是否确实对应TLS呈现叶证书、TLS1.2 AES-GCM支持、DDI/CoreDeviceProxy可用性
5. 测CDTunnel和lwIP/RSD，确认小窗口与分片拒绝profile兼容；再由PNG sink提交一张完整图
6. 在当前截图基础上测试可逆Home，区分TCP ACK与实际界面变化；遇不确定结果不自动重放
7. 核实媒体启动答案中的本次流token与安全停止。未经核实不猜字段、不把协商session_id当token、不自动stopAll
8. 分别测内部SRAM、PSRAM、DMA、堆栈与长时间RTP负载。源代码静态数字不能替代水位测试
9. 独立iOS App的版本化协议另行交付；v0.3尚未有Appchannel，认证和同线usbmux可达性须真正实现后联测

新的事实应继续记录到原项目Page，保留Mac已验证基线与本项目未验证项。
固件源码归档保持同一Library身份的版本历史；工作区丢失时恢复归档后核对SOURCE_MANIFEST.json。

复现入口：tools/test_all.sh、tools/build_firmware.sh；单层测试脚本名称与模块对应。
全量测试依赖官方ESP-IDF源码和Python包，归档不附整份SDK或真实证书。
