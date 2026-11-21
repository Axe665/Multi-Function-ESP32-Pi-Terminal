# artifacts（v2 历史产物）

本目录保留 2026-11 之前的 **API v2** 签名包和比赛构建产物，只用于追溯：

- 当前 devkit 已升级到 **API v3 / Qt 6.5.3**（`platform_api=2`、`min_host_api=3`、
  `data_schema`），这些 v2 包不能装到 v3 宿主；
- 对应的签名私钥不在仓库里，本轮不重新签名；
- 重新生成可信包前不得对外分发本目录内容。

新的 v3 包请从模块工程重新构建、签名，再按 `docs/PHYSICAL-PI-TEST.md` 验收。
