# riasopy

Spatial omics data analysis framework with a Rust core and Python bindings.

## Installation

```bash
pip install riasopy
```

Requires Python 3.11+ 

## Quick start

```python
import riasopy

sd = riasopy.read_h5ad("sample1.h5ad")
sd.cal_qc()
sd.filter_cells(min_counts=200, min_genes=3, pct_counts_mt=10)
sd.normalize_total()
sd.highly_variable_genes(n_top_genes=2000)
sd.pca(n_pcs=30)
sd.neighbors(n_neighbors=10)
sd.umap()
sd.leiden(resolution=1.0)
sd.marker_genes()
```

## Reading data

- `read_gef(path, bin_size=100, ...)` — GEF (Stereo-seq) files, square or cell bins.
- `read_gem(path, bin_size=100, ...)` — GEM text files (plain or gzipped).
- `read_h5ad(path, spatial_key="spatial", ...)` — AnnData h5ad files.

## Cell type annotation (SingleR)

```python
reference = riasopy.read_singler_ref("refs/reference.h5ad", label_key="label.main")
result = sd.singler(reference)
# result = {"first_labels", "final_labels", "labels", "scores"}
```

## Gene set enrichment

```python
go = riasopy.read_go_db("go.sqlite")
sd.run_ora(go)
sd.run_gsea(go)
```

## License

MIT
