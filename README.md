# 空间转录组反卷积项目

当前模型为 **老版五损失＋加权KL**。2026-10-25已按模块整理，
完整说明见 [模型README](CellMixDMF_GeneWeightedKL/README.md)。

| 目录 | 内容 |
|---|---|
| `CellMixDMF_GeneWeightedKL/` | 唯一维护的自研模型：模型、损失、预处理、训练、输入输出 |
| `Benchmark_Spotless/` | 三方法基准：转换、训练、评价、报告、诊断与补跑 |
| `environments/` | RCTD、Cell2location独立环境及安装检查 |
| `REF/` | 原11个参考RDS对象，以及新增BC、癌症单细胞参考和GSE113576参考表达三件套 |
| `DATA/` | 原650份银标准、15份金标准，以及新增Xenium、MERFISH和癌症多平台空间数据压缩包 |
| `OUTPUT/` | 实验结果、报告和整理核对记录 |

环境配置：[模型environment.yml](CellMixDMF_GeneWeightedKL/environment.yml)。
现有环境为 `D:/conda-envs/cellmix_dmf`、`D:/conda-envs/rctd`、`D:/conda-envs/cell2location`。

```powershell
& 'D:/conda-envs/cellmix_dmf/python.exe' -B CellMixDMF_GeneWeightedKL/run.py --check-only
```

数据与历史实验结果保留。重复实现、未使用上游分支、字节码缓存已清理。
2026-10-27新增数据已按参考/空间待测归类，见[数据整理清单](OUTPUT/DataOrganization_20261027/README.md)。GSE113576已补齐作者细胞类型标签表，31299个细胞ID全部匹配。
一次性排错脚本从活动目录移除，整理前源码压缩保留在
`OUTPUT/CodeCleanup_20261025/source_before_cleanup.zip`。
变更与等价性记录见 `OUTPUT/CodeCleanup_20261025/README.md`。
