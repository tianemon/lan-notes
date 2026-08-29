# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v1.0.0] - 2026-08-29

### Added

- 笔记增删改查、搜索、回收站（删除进回收站，可恢复/清空），本地持久化（drift / SQLite）
- 富文本编辑（flutter_quill）：加粗 / 斜体 / 标题 / 列表 / 引用 / 代码块 / 本地插图，存量纯文本笔记自动迁移
- 文件夹归类：文件夹增删改、置顶、拖拽排序，笔记归属跨设备同步
- 局域网设备发现：UDP 广播通告（参考 Syncthing / LocalSend），「可被发现」+「扫描设备」手动互联
- P2P 对等同步：WebSocket 点对点（固定端口 58888），握手 → 全量对齐 → 增量推送，多设备全互联 mesh
- 配对协议：请求-同意配对 + HMAC 挑战认证，取消配对双边解除
- 冲突处理：版本号 + 最后写入时间（LWW）合并，版本单调递增
- 断线重连：重新上线方凭地址缓存自动直连并全量对齐
- 图片跨设备同步：附件自动请求 → 分片传输 → sha256 校验落盘
- 设备 ID 冲突检测与重置身份
- 跨平台支持：iOS / Android / Windows / macOS
