# RIASO — Rapid And Intelligent Analyzer for Spatial Omics

RIASO provides ultrafast preprocessing, visualization, clustering, cell annotation and gene enrichment for spatial transcriptomics data. Its Rust core handles GEF/GEM (Stereo-seq) and h5ad (Scanpy) inputs.

The CLI runs the whole analysis chain in one command. For fine-grained control, the Python bindings expose the same steps with every parameter available.

## Contents

- [Features](#features)
- [riaso](#riaso)
  - [simple usage](#simple-usage)
  - [get riaso](#get-riaso)
    - [install with Bioconda](#install-with-bioconda)
    - [or compile from source](#or-compile-from-source)
  - [All options](#all-options)
- [riasopy](#riasopy)
  - [get riasopy](#get-riasopy)
    - [install with pip](#install-with-pip)
    - [compile from source](#compile-from-source)
  - [All API](#all-api)
    - [1. Module-level functions](#1-module-level-functions)
      - [1.1 `read_gef`](#11-read_gef)
      - [1.2 `read_gem`](#12-read_gem)
      - [1.3 `read_h5ad`](#13-read_h5ad)
      - [1.4 `read_singler_ref`](#14-read_singler_ref)
      - [1.5 `read_go_db` / `read_kegg_db` / `read_reactome_db`](#15-read_go_db--read_kegg_db--read_reactome_db)
      - [1.6 `integrate`](#16-integrate)
    - [2. `SoData` — Attributes](#2-sodata--attributes)
    - [3. `SoData` — Methods](#3-sodata--methods)
      - [3.1 QC and filtering](#31-qc-and-filtering)
      - [3.2 Normalization and feature selection](#32-normalization-and-feature-selection)
      - [3.3 Dimensionality reduction](#33-dimensionality-reduction)
      - [3.4 Clustering](#34-clustering)
      - [3.5 Marker genes](#35-marker-genes)
      - [3.6 Cell annotation](#36-cell-annotation)
      - [3.7 Enrichment analysis](#37-enrichment-analysis)
      - [3.8 Plotting methods](#38-plotting-methods)

## Features

The benchmark uses a 2,931-spot × 27,154-gene mouse brain slice, comparing riaso with scanpy, stereopy, Seurat and Giotto.

riaso is substantially faster (all times in seconds):

| Step | riaso | scanpy | stereopy | Seurat | Giotto |
| --- | --- | --- | --- | --- | --- |
| Read | 1.03 | 3.02 | 2.45 | 10.67 | 13.65 |
| QC | 0.05 | 0.68 | 1.45 | 0.66 | – (merged into filter) |
| Filter | 0.24 | 0.33 | 0.61 | 0.75 | 0.57 |
| Normalize + log1p | 0.03 | 13.48 | 0.25 | 2.28 | 4.68 |
| HVG | 0.06 | 2.25 | 1.48 | 2.85 | 0.75 |
| Scale | 0.29 | 0.67 | 0.62 | 0.50 | 6.41 |
| PCA | 6.95 | 11.01 | 0.52 | 1.01 | 7.79 |
| Neighbors | 0.16 | 22.32 | 10.45 | 0.67 | 0.58 |
| UMAP | 1.39 | 5.94 | 4.35 | 5.71 | 6.21 |
| Clustering | 0.02 | 5.42 | 0.55 | 0.27 | 3.35 |
| Marker genes | 1.69 | 9.42 | 5.95 | 370.9 | 157.2 |
| Total | ≈12 | ≈75 | ≈29 | ≈396 | ≈201 |

Peak memory usage is also lower:

| Tool | Peak memory (GB) | Stage of peak memory |
| --- | --- | --- |
| riaso | 1.67 | marker |
| scanpy | 2.00 | scale / marker |
| stereopy | 2.14 | marker |
| Giotto | 3.75 | marker |
| Seurat | 4.11 | marker |

## riaso

`riaso` is RIASO at the command line: one self-contained binary, no Python environment needed.

Point it at an input with `-I` and it runs the default chain in one go — read, QC, filter cells, normalize, log1p, scale, HVG, PCA, neighbors, UMAP, clustering, marker genes and the HTML/JSON reports — writing the result tree under `-O` (default `./result`). Cell annotation (`-a`) and enrichment (`-G` / `-K` / `-R`, with `-E` for GSEA) are opt-in and need their reference files.

Repeat `-I` (or pass a directory) to process several samples: without `-i` every input is analyzed independently as its own single sample; add `-i` to merge them into one object. An integrated run applies harmony batch correction automatically after PCA.

See simple usage below for a first run, all options for the full flag list.

### simple usage

* the default chain is QC -> filter cells -> normalize -> log1p -> scale -> HVG -> PCA ->
  neighbors -> UMAP -> Leiden -> marker genes -> report. It needs no external file:
```
riaso -I sample.gef -O ./result
```
* examples
```
riaso -I sample.gef -O ./result \
      -a --reference refs/reference.h5ad \
      -G --go-db go/GO.db/inst/extdata/GO.sqlite \
      -K --kegg-dir kegg/raw \
      --kegg-org mmu \
      -R --reactome-dir reactome/raw \
      --reactome-species "Mus musculus" \
      --org-db go/org.Mm.eg.db/inst/extdata/org.Mm.eg.sqlite
```
  * `-a` requires at least one `--reference`.
  * `-G` / `-K` / `-R` require the shared `--org-db` plus their own library path.
  * `--kegg-org mmu` and `--reactome-species "Mus musculus"` are mouse defaults; for another
    species change them **and** `--org-db` (see the notes under those flags below).
* multiple inputs without `-i` are analyzed as independent samples (one output subdirectory each):
```
riaso -I sample1.gef -I sample2.gef -O ./result
```
* add `-i` to integrate the inputs into one object. All inputs must share the same extension
  (`.gef`, `.gem` or `.h5ad`; no mixing), and harmony batch correction then runs automatically:
```
riaso -I sample1.gef -I sample2.gef -i -O ./result
```
* every run also writes two summaries next to the analysis products:
  * `report.json` — machine-readable run summary.
  * `report.html` — a single-file report.

* the output directory looks roughly like this (`-O ./result`, input stem `sample`, bin size 100):

```
result/
  run_sample/                                              # one directory per analysis
    sample_Riaso/                                          # tables, plots and reports
      report.json                                          # machine-readable run summary (always written)
      report.html                                          # single-file report (always written)
      sample_100_Violin.png                                # QC violin
      sample_100_Genes_Count.png                           # QC histogram (single sample only)
      sample_100_Spatial_Scatter_total_counts.png
      sample_100_Spatial_Scatter_n_genes_by_counts.png
      sample_100_Spatial_Scatter_pct_counts_mt.png
      sample_100_Highly_Variable_Genes.png
      sample_100_Elbow.png                                 # PCA scree plot
      sample_100_Cluster_Leiden.png                        # clusters in tissue space
      sample_100_Cluster_Leiden_Umap.png
      sample_100_Marker_Gene.csv                           # long table: all clusters, ranked by scores
      sample_100_Marker_Gene_Filter.csv                    # wide table: filtered, ranked by log2fc
      sample_100_Marker_Gene_Filter_Top5_heatmap.png
      sample_100_Marker_Gene_Filter_Top5_scatter.png       # integrated runs write _dotplot.png
      sample_100_MarkerTop5_cluster{K}_{gene}.png          # top 5 genes per cluster, {K} = cluster ID
      sample_100_SingleR_Metadata.csv                      # only with -a
      sample_100_SingleR_Heatmap_{ref}.png                 # only with -a
      sample_100_scatter_{ref}.png                         # only with -a
    sample_Pathways/                                        # per-cluster tables (marker genes on)
      cluster{K}/
        MarkerGeneFilter.xls                                # always with marker genes
        Pathway_GO.xls                                      # only with -G
        Pathway_KEGG.xls                                    # only with -K
        Pathway_Reactome.xls                                # only with -R
        Pathways_GO_Top10.png                               # only with -G
        Pathways_KEGG.png                                   # only with -K
        Pathways_Reactome.png                               # only with -R
        GSEA_GO_dotplot.png                                 # only with -E
        GSEA_GO_barplot.png
```

### get riaso

#### install with Bioconda

```shell
# note: the riaso version in bioconda may be not the latest
conda install -c bioconda riaso
```

#### or compile from source

`riaso` needs a Rust toolchain (rustc/cargo >= 1.93). The self-contained bundle additionally uses conda for its HDF5, ARPACK and font dependencies.

##### Step 1: install dependencies

Create the provided conda environment:
```shell
conda env create -f riaso/environment-linux.yml
```
The build script activates it by name (`riaso`) itself.

##### Step 2: build riaso

```shell
bash riaso/scripts/build_binary.sh
```
This produces a movable `riaso/dist/` directory. Its entry point is `dist/riaso`; it can run without any environment setup:
```shell
./dist/riaso -I sample.gef -O ./result
```

To pack the same tree into a single conda package instead:
```shell
bash riaso/scripts/build_conda_package.sh
# -> riaso/dist-conda/riaso-<version>-<build>.conda
```

### All options

Steps shown as `(bool [=true])` are on by default and can be disabled with `--flag false`
(e.g. `--qc false`). Options without a value (shown without a `bool` annotation) are plain
switches that are off unless present.

```shell
usage: riaso -I <input> [-I <input2> ...] [-O <out_dir>] [options...]
options:
  # I/O options
  -I, --input <path>            input file or directory, repeatable for multi-sample (string)
                                file: type auto-detected by extension (.gef/.gem -> GEF, .h5ad -> H5AD)
                                directory: top-level *.gef/*.gem/*.h5ad, each file = one sample, sorted by name
      --bin-type <t>            GEF bin type: bins|cell_bins (string [=bins])
      --bin-size <n>            GEF bin edge length, unit DNB / 500nm (int [=100])
      --spatial-key <key>       obsm key holding spatial coords in h5ad (string [=spatial])
      --dense                   read dense matrix instead of sparse (default sparse)
      --no-dedup-symbols        keep duplicated gene symbols (default dedup, aligned with stereo)
  -i, --integrate               merge all -I inputs into one multi-sample object (off by default)
                                needs >=2 inputs of the same extension; without -i every input
                                is analyzed independently; harmony then runs automatically
  -O, --output <dir>            output root directory (string [=./result])


  # Data preprocessing options
  -q, --qc                      run quality control (total_counts / n_genes_by_counts / pct_counts_mt) (bool [=true])
  -f, --filter-cells            filter low-quality cells (bool [=true])
      --min-counts              min total counts per cell (float [=200])
      --max-counts              max total counts per cell (float [=off])
      --min-genes               min detected genes per cell (int [=3])
      --max-genes               max detected genes per cell (int [=off])
      --pct-mt                  max mitochondrial percentage (float [=10.0])
      --cell-list <file>        cell whitelist, one name per line (string)
      --exclude-cells           treat --cell-list as blacklist instead of whitelist
  -g, --filter-genes            filter lowly-expressed genes
      --min-cells               min cells expressing a gene (int [=off])
      --max-cells               max cells expressing a gene (int [=off])
      --gene-min-counts         min total UMI of a gene (float [=off])
      --gene-max-counts         max total UMI of a gene (float [=off])
      --gene-mean-umi           min mean UMI of a gene (float [=off])
      --gene-list <file>        gene whitelist, one name per line (string)
      --exclude-genes           treat --gene-list as blacklist instead of whitelist
      --filter-mt-genes         drop mt- / mt. genes unconditionally
  -x, --filter-coordinates      crop cells by a spatial bounding box
      --min-x / --max-x         X bounds (closed interval, float)
      --min-y / --max-y         Y bounds (closed interval, float)
  -n, --normalize-total         normalize total counts (CP10K by default) (bool [=true])
      --target-sum              target total count after normalization (float [=10000.0])
  -l, --log1p                   apply ln(1+x) (bool [=true])
  -s, --scale                   z-score scale (bool [=true]); subtracts the mean before scaling, aligned with stereo
      --no-zero-center          keep the mean: skip mean subtraction before scaling
      --max-value               clip scaled values above this value (float [=off])
      --n-top-genes             number of top variable genes (int [=2000])
      --n-bins                  bins for dispersion normalization (int [=20])
  -h, --hvg <method>            HVG selection method: seurat | cell_ranger (string [=seurat])
      --no-hvg                  PCA ignores the HVG subset and runs on the full gene matrix (HVG is still computed and plotted)
      
  # Clustering options
  -p, --pca                     run PCA (bool [=true])
      --n-pcs                   number of principal components (int [=30])
      --svd-solver              auto|full|arpack|randomized (string [=auto])
  -b, --harmony                 request harmony explicitly; an integrated (-i) run already
                                applies it automatically, and a single sample has no batch
                                column, so this flag has no effect there
      --sigma                   cluster soft-assignment width (float [=0.1])
      --theta                   batch diversity penalty (float [=auto])
      --lamb                    cluster diversity penalty (float [=auto])
      --tau                     assignment matrix power (float [=0.0])
      --block-size              fraction of cells per iteration (float [=0.05])
      --max-iter-harmony        outer iterations (int [=10])
      --max-iter-kmeans         inner kmeans iterations (int [=20])
      --epsilon-cluster         kmeans convergence (float [=1e-5])
      --epsilon-harmony         outer convergence (float [=1e-4])
      --nclust                  number of clusters (int [=auto])
  -k, --neighbors               build neighbors graph (bool [=true])
      --n-neighbors             number of neighbors (int [=10])
      --n-pcs-neighbors         use first N PCs only (int [=all])
  -u, --umap                    UMAP embedding (bool [=true])
      --umap-components         output dimensions (int [=2])
      --min-dist                min distance in low-dim space (float [=0.5])
      --spread                  embedding scale (float [=1.0])
  -c, --clustering <alg>        leiden|louvain (string [=leiden])
      --resolution              clustering resolution (float [=1.0])
  -m, --marker-genes            find marker genes (bool [=true])
      --top-n                   top N marker genes per cluster (int [=5])
                                shared by the long table, heatmap, dotplot and per-cluster spatial plots

  # Cell annotation options
  -a, --singler                 SingleR cell annotation (off by default; pass this flag to enable)
      --reference <file>        SingleR reference h5ad, repeatable (needed with -a)
      --label-key <key>         SingleR label column in reference obs (string [=label.fine])
      --quantile                score quantile for coarse scoring (float [=80.0])
      --fine-tune-threshold     absolute score-gap threshold for fine tuning (float [=0.05])
      --fine-tune-times         max fine-tuning rounds, 0 = unlimited (int [=0])

  # Gene enrichment options (ORA: GO/KEGG/Reactome)
  -G, --go                      run ORA against GO (off by default; pass this flag to enable)
      --go-db <file>            GO.sqlite (needed with -G)
      --ora-category            GO ontology only: BP|CC|MF (string [=all])
  -K, --kegg                    run ORA against KEGG (off by default; pass this flag to enable)
      --kegg-dir <dir>          KEGG raw directory (needed with -K)
      --kegg-org <code>         KEGG three-letter organism code (string [=mmu], `mmu` = mouse)
                                the default is mouse only; for any other species pass this flag
                                (e.g. `hsa` = human, `rno` = rat), or the lookup fails with
                                "failed to open the KEGG gene-to-pathway file"
  -R, --reactome                run ORA against Reactome (off by default; pass this flag to enable)
      --reactome-dir <dir>      Reactome raw directory (needed with -R)
      --reactome-species <name> species name as spelled in NCBI2Reactome (string [="Mus musculus"],
                                the mouse scientific name), e.g. "Homo sapiens" for human
                                the default is mouse only; the name is matched literally, so a
                                mismatch silently yields an empty database (no error)
  # shared by -G / -K / -R
      --org-db <file>           org.*.eg.sqlite for symbol/Entrez mapping (needed with any of -G/-K/-R)
                              must be the org database of the same species
      --gene-pvalue-cutoff      input-gene pvalue cutoff (float [=0.05])
      --gene-log2fc-cutoff      input-gene log2fc cutoff (float [=1.0])
      --ora-pvalue-cutoff       term pvalue cutoff (float; when given, overrides all three DBs)
                              default is per-DB: GO/KEGG 0.05, Reactome 1.0
      --ora-qvalue-cutoff       term qvalue cutoff (float; when given, overrides all three DBs)
                              default is per-DB: GO/KEGG 0.2, Reactome 1.0
      --min-gene-count          min gene set size (int [=10])
      --max-gene-count          max gene set size (int [=500])
    --top-n-terms             max terms per cluster (int [=500])

  # Gene enrichment options (GSEA)
  -E, --gsea                    run pre-ranked GSEA (off by default); reuses the ORA libraries,
                              so at least one of GO/KEGG/Reactome must stay on
    --gsea-rank-by            log2fc|tstat|score (string [=log2fc])
    --gsea-param              weight exponent p (float [=1.0])
    --gsea-min-gene-count     min gene set size (int [=10])
    --gsea-max-gene-count     max gene set size (int [=500])
    --gsea-n-perm             permutation count (int [=1000])
    --gsea-seed               permutation seed (int [=0])
    --gsea-pvalue-cutoff      term pvalue cutoff (float [=0.05])
    --gsea-qvalue-cutoff      term qvalue cutoff (float [=0.25])
    --gsea-top-n-terms        max terms per cluster (int [=20])

# Global options
    --random-seed <n>             random seed, shared by PCA / harmony / UMAP / leiden / louvain (int [=0])
    --threads <n>                 rayon global thread pool size; 0 = leave it alone (int [=0])

# help
  -V, --version                 print the version and exit
  -H, --HELP                    print this message (-h is taken by --hvg)
```

## riasopy

RIASO also ships a Python extension module, built with pyo3 and maturin from the same Rust core. It exposes the same analysis steps as the CLI, but does not generate the HTML/JSON reports.

### get riasopy

#### install with pip

Requires Python >= 3.11 (the wheel is `cp311-abi3`)

```shell
pip install riasopy
```
If the package is not yet available from your package index, build the wheel from source below and install the file directly:
```shell
pip install riasopy/target/wheels/riasopy-*.whl
```

#### compile from source

`riasopy` is compiled with maturin and a Rust toolchain (rustc/cargo >= 1.93).

##### Step 1: install dependencies

Create the provided build environment (named `riasopy-build`):
```shell
conda env create -f riasopy/environment-linux.yml
```

##### Step 2: build the wheel

```shell
bash riasopy/scripts/build_wheel.sh
# -> riasopy/target/wheels/riasopy-<version>-cp311-abi3-*.whl
```
The script activates `riasopy-build` itself (override with `RIASOPY_ENV`), assembles the font assets and rewrites the extension's RPATH so the wheel is self-contained: the non-system shared libraries and DejaVu fonts are bundled, and the build environment is not needed at runtime. Install it with:
```shell
pip install riasopy/target/wheels/riasopy-*.whl
```

### All API

#### 1. Module-level functions

```python
import riasopy as rs
```

##### 1.1 `read_gef`

```python
read_gef(path, *, bin_type="bins", bin_size=100, is_sparse=True,
         dedup_symbols=False, save_counts_layer=False,
         save_exon_layer=False) -> SoData
```

Read a Stereo-seq `.gef` file. `bin_type` is `"bins"` (square bins) or `"cell_bins"` (segmented cells). `save_exon_layer=True` additionally stores the exon (spliced) counts of the same bin as a sparse matrix under `layers["exon"]`.

##### 1.2 `read_gem`

```python
read_gem(path, *, bin_size=100, is_sparse=True, dedup_symbols=False,
         save_counts_layer=False, save_exon_layer=False) -> SoData
```

Read a Stereo-seq `.gem` file. Same options as `read_gef` (`save_exon_layer=True` sums the `ExonCount` column into `layers["exon"]`), but there is no `bin_type`: `.gem` only carries square bins.

##### 1.3 `read_h5ad`

```python
read_h5ad(path, *, spatial_key="spatial", save_counts_layer=False) -> SoData
```

Read an AnnData `.h5ad` file (scanpy). `save_counts_layer=True` keeps a copy of the raw counts under `layers["counts"]` before any normalization. Gene names are read from the `var` index (`var.attrs["_index"]`, falling back to the `_index` column); cell names come from the `obs` index in the same way.

##### 1.4 `read_singler_ref`

```python
read_singler_ref(path, *, label_key="label.main", gene_key=None) -> SingleRRef
```

Read an h5ad file as a SingleR reference set. The result is a `SingleRRef` you pass to `singler()`; it exposes `ref_x`, `ref_genes`, `ref_labels`, `shape` (`(n_cells, n_genes)`), `n_cells` and `n_genes`. You can also build one straight from arrays with `SingleRRef(ref_x, ref_genes, ref_labels)`, which is handy when the reference does not come from an h5ad file. `label_key` defaults to `label.main` here. `gene_key` selects an alternative `var` column for gene names (the `var` index is used when it is `None`). The object's `repr` is `SingleRRef(n_cells=..., n_genes=...)`.

##### 1.5 `read_go_db` / `read_kegg_db` / `read_reactome_db`

```python
read_go_db(org_path, go_path) -> GeneSetDb
read_kegg_db(kegg_dir, org_path, org) -> GeneSetDb
read_reactome_db(reactome_dir, org_path, species) -> GeneSetDb
```

Build a gene set database for enrichment analysis. All three produce the same `GeneSetDb` type; `run_ora` / `run_gsea` do not care where it came from. `org_path` is the `org.*.eg.sqlite` used for symbol/Entrez mapping, and must belong to the same species as `org` / `species`. The database name carried by the returned object (used as the `db_name` of the enrichment plots) is `"go"` / `"kegg"` / `"reactome"`. `GeneSetDb` exposes `n_sets` and its `repr` is `GeneSetDb(n_sets=...)`.

##### 1.6 `integrate`

```python
integrate(samples, *, var_type="intersect", save_counts_layer=False) -> SoData
```

Merge multiple samples into one `SoData` (`samples` is a list of `SoData`, at least 2). `var_type="intersect"` (the default) keeps the shared genes, while `"union"` keeps all genes; the sample name of each cell is recorded in `obs["batch"]`. `save_counts_layer=True` keeps a copy of the raw counts under `layers["counts"]`.

---

#### 2. `SoData` — Attributes

```python
SoData()          
```

`repr` looks like `SoData(n_cells=..., n_genes=..., n_samples=...)`.

| Attribute | Type |
| --- | --- |
| `shape` | `(int, int)` |
| `n_cells` | `int` |
| `n_genes` | `int` |
| `is_sparse` | `bool` |
| `X` | `np.ndarray (n_cells, n_genes) float64` |
| `obs` | `dict[str, list \| np.ndarray]` |
| `var` | `dict[str, list \| np.ndarray]` |
| `position` | `np.ndarray (n_cells, 2) float64` or `None` |
| `raw` | `SoData` or `None` |
| `names` | `list[str]` — sample names |
| `n_samples` | `int` — number of samples |
| `var_type` | `str` — `"intersect"` or `"union"` |

---

#### 3. `SoData` — Methods

##### 3.1 QC and filtering

###### `cal_qc()`

```python
cal_qc() -> None
```

**Input**: any `SoData` with data loaded.

###### `filter_cells(...)`

```python
filter_cells(min_counts=None, max_counts=None, min_genes=None, max_genes=None,
             pct_counts_mt=None, cell_list=None, excluded=False,
             *, write_layer=False) -> None
```

Filter by cell-level metrics, keeping cells that satisfy every condition. `None` disables that condition; multiple conditions are ANDed.

###### `filter_genes(...)`

```python
filter_genes(min_cells=None, max_cells=None, min_counts=None, max_counts=None,
             mean_umi_gt=None, gene_list=None, excluded=False,
             filter_mt_genes=False, *, write_layer=False) -> None
```

Filter by gene-level metrics, keeping genes that satisfy every condition.

###### `filter_coordinates(...)`

```python
filter_coordinates(min_x=None, max_x=None, min_y=None, max_y=None, *,
                   write_layer=False) -> None
```

Crop cells with a rectangular bounding box in spatial coordinates, keeping those inside the box.

##### 3.2 Normalization and feature selection

###### `normalize_total(...)`

```python
normalize_total(target_sum, *, write_layer=False) -> None
```

Divide each cell's counts by its own total, then multiply by `target_sum` (i.e. `target_sum=1e4` for CP10K).

###### `log1p(...)`

```python
log1p(*, write_layer=False) -> None
```

Apply `ln(1 + x)` element-wise to `X`.

###### `scale(...)`

```python
scale(*, zero_center=False, max_value=None, write_layer=False) -> None
```

Per-gene scaling. `zero_center=True` subtracts the gene mean before dividing by the standard deviation (a true z-score); the default `False` only divides by the standard deviation, which keeps sparse matrices sparse. `max_value` clips values above that bound. **Important**: before scaling, an unscaled copy of the log1p matrix is snapshotted into `layers["log1p"]`, which `marker_genes` later prefers.

###### `highly_variable_genes(...)`

```python
highly_variable_genes(method="seurat", n_top_genes=2000, n_bins=20) -> None
```

Select highly variable genes. The input should already be log1p-transformed. `method` is `"seurat"` (binned normalized dispersion, the default) or `"cell_ranger"` (dispersion on raw counts); **any other string is silently ignored** — no error is raised, and no HVG result is produced.

##### 3.3 Dimensionality reduction

###### `pca(...)`

```python
pca(n_components=30, svd_solver="auto", dtype="float32", random_state=0) -> dict
```

Principal component analysis. `svd_solver` is `"auto"`, `"full"`, `"arpack"` or `"randomized"`, and `dtype` is `"float32"` or `"float64"`. **Always consumes only the columns where the internal `result.hvg.highly_variable` is `True`**; if hvg was never run, it silently falls back to using all genes. Returns a dict with `projected` (cells × PCs), `components` (PCs × genes), `explained_variance`, `explained_variance_ratio`, `mean` and `total_variance`.

###### `harmony(...)`

```python
harmony(sigma=0.1, theta=None, lamb=None, tau=0.0, block_size=0.05,
        max_iter_harmony=10, max_iter_kmeans=20, epsilon_cluster=1e-5,
        epsilon_harmony=1e-4, random_state=0, nclust=None) -> np.ndarray
```

Multi-sample batch correction. **Input**: `pca()` must have run first, and `obs["batch"]` must exist (it comes from `integrate()`). Returns the corrected `(n_cells, k)` float64 array.

###### `neighbors(...)`

```python
neighbors(pca_res_key=None, n_neighbors=10, n_pcs=None) -> dict
```

Nearest-neighbor graph. `pca_res_key` is **currently ignored** (a placeholder parameter kept for stereopy signature compatibility). Returns a dict with `neighbor` (the integer index matrix), `connectivities` and `nn_dist`. For small datasets these last two are dense arrays; above the internal dense-kNN threshold they are a sparse dict with `data` / `indices` / `indptr`.

###### `umap(...)`

```python
umap(n_components=2, min_dist=0.5, spread=1.0, random_state=0) -> None
```

`neighbors()` must have run first.

##### 3.4 Clustering

###### `leiden(...)`

```python
leiden(resolution=1.0, random_state=0) -> None
```

`neighbors()` must have run first. Labels land in `obs["leiden"]`.

###### `louvain(...)`

```python
louvain(resolution=1.0, random_state=0) -> None
```
As above. Labels land in `obs["louvain"]`.

##### 3.5 Marker genes

###### `marker_genes(...)`

```python
marker_genes(cluster_key="leiden", *, top_n=10) -> dict
```

Case-vs-control differential expression test for each cluster. **Input**: `obs[cluster_key]` must exist. Returns a dict with one entry per cluster under `clusters`; each entry has `cluster_id`, `genes`, `log2fc`, `p_adj`, `mean_count`, `pct` and `pct_rest` (at most `top_n` genes).

###### `write_marker_csv(...)`

```python
write_marker_csv(path, *, top=None) -> None
```

Write the `marker_genes()` result to CSV. **Input**: `marker_genes()` must have run first.

##### 3.6 Cell annotation

###### `singler(...)`

```python
singler(reference, cluster_labels=None, quantile=80.0,
        fine_tune_threshold=0.05, fine_tune_times=0) -> dict
```

Label cells against a reference set (SingleR algorithm). When `cluster_labels` is given, expression profiles are aggregated per cluster, annotated, then spread back to every cell in that cluster; when `None`, cells are annotated individually.

Returns a dict with `first_labels`, `final_labels`, `labels` and `scores`; when `cluster_labels` is passed it also contains `clusters`.

##### 3.7 Enrichment analysis

###### `run_ora(db, ...)`

```python
run_ora(db, *, category=None, gene_pvalue_cutoff=0.05, gene_log2fc_cutoff=0.5,
        pvalue_cutoff=0.05, qvalue_cutoff=0.05, min_gene_count=5,
        max_gene_count=500, top_n_terms=20) -> dict
```

Over-representation analysis (hypergeometric test + BH correction). `marker_genes()` must have run first — the input genes are filtered per cluster out of `result.marker`. Returns `{db_name: {"n_groups": ..., "clusters": [{"cluster_id": ..., "terms": [...]}]}}`, where each term carries `id`, `name`, `category`, `pvalue`, `pvalue_adj`, `count`, `overlap`, `gene_ratio` and `bg_ratio`.

###### `run_gsea(db, ...)`

```python
run_gsea(db, *, category=None, rank_by="log2fc", gsea_param=1.0,
         min_gene_count=10, max_gene_count=500, n_perm=1000, seed=0,
         pvalue_cutoff=0.05, qvalue_cutoff=0.25, top_n_terms=20) -> dict
```

`marker_genes()` must have run first. The ranked list comes from the internal `result.marker` (**all-gene** result). Returns the same shape as `run_ora()`; each term carries `id`, `name`, `category`, `es`, `nes`, `pvalue`, `pvalue_adj`, `size`, `rank_at_es` and `leading_edge`.

##### 3.8 Plotting methods

All plotting methods accept `path` (write a PNG there) or `return_bytes=True` (return the PNG as `bytes`); if neither is given, an error is raised. `width` / `height` are pixels.

###### `plot_qc(...)`

```python
plot_qc(path=None, *, kind="violin", metrics=None, title=None,
        width=None, height=None, return_bytes=False)
```

QC metric distribution plots. `kind="violin"` draws violins and `kind="hist"` draws histograms, one panel per metric; with `metrics=None` it plots `total_counts` / `n_genes_by_counts` / `pct_counts_mt`.

###### `plot_spatial_scatter(...)`

```python
plot_spatial_scatter(path=None, *, color_by="total_counts", ncols=3, dot_size=None,
                     title=None, width=None, height=None, vmin=None, vmax=None,
                     return_bytes=False)
```

Scatter points at their spatial coordinates and color them with a continuous colormap driven by a **numeric `obs` column** (default `total_counts`, not a gene name). When `obs["batch"]` holds several batches it automatically splits into subplots using `ncols`.

###### `plot_highly_variable_genes(...)`

```python
plot_highly_variable_genes(path=None, *, width=None, height=None, return_bytes=False)
```

Highly variable gene scatter: the X axis is per-gene mean expression (`means`), the Y axis is binned, normalized dispersion (`dispersions_norm`), and the selected HVGs are highlighted.

###### `plot_marker_heatmap(...)`

```python
plot_marker_heatmap(path=None, *, cluster_key="leiden", top_n=5, groups=None,
                    title=None, width=None, height=None, return_bytes=False)
```

Marker gene heatmap: genes in rows, clusters in columns, cell value = mean expression within that cluster (standardized per gene). Genes are grouped by their cluster with braces, and each gene block lines up with its matching columns.

###### `plot_marker_dotplot(...)`

```python
plot_marker_dotplot(path=None, *, cluster_key="leiden", top_n=5, groups=None,
                    title=None, width=None, height=None, return_bytes=False)
```

Marker gene dot plot: the same genes-in-rows, clusters-in-columns layout with genes blocked by cluster. **Dot radius ∝ the fraction of cells in that cluster expressing the gene** (√-scaled), **color = mean expression within that cluster** (standardized per gene). A colorbar and a dot-size legend sit on the right.

###### `plot_marker_spatial(genes, ...)`

```python
plot_marker_spatial(genes, path=None, *, title=None, width=None, height=None,
                    dot_size=None, vmin=None, vmax=None, return_bytes=False)
```

Plot the spatial expression abundance of the given genes using `position`, **one subplot per gene**. Expression values come from the processed `exp_matrix`, and the palette is a reversed fire (higher expression is darker). Single-sample lays out 2 columns; multi-sample uses 3 columns and further splits each gene by sample.

###### `plot_singler_score_heatmap(...)`

```python
plot_singler_score_heatmap(path=None, *, max_labels=40, normalize=True,
                           title=None, width=None, height=None, return_bytes=False)
```

SingleR match-score heatmap of **reference cell type × cluster**, the counterpart of R's `SingleR::plotScoreHeatmap`. Rows = cell types (names labeled on the left), columns = clusters (IDs labeled at the bottom, ordered by "the cell type assigned to that cluster" so identical types sit together). Two annotation bars on top: the upper one is the cluster ID, the lower one is the cell type assigned to that cluster; on the right sit the score colorbar and a two-column legend.

> **Prerequisite**: `singler(cluster_labels=...)` must have been run in **cluster mode** first; per-cell mode (`clusters` empty) or never having run `singler` both raise an error.

###### `plot_umap(...)`

```python
plot_umap(path=None, *, cluster_key="leiden", title=None, x_label="umap1",
          y_label="umap2", dot_size=None, width=None, height=None, return_bytes=False)
```

2-D UMAP scatter, colored by `cluster_key`, with axis titles defaulting to `umap1` / `umap2`.

###### `plot_pca_variance_ratio(...)`

```python
plot_pca_variance_ratio(path=None, *, n_pcs=30, cum=False, log=False,
                        width=None, height=None, return_bytes=False)
```

Scree (elbow) plot: the X axis is the PC, the Y axis is the variance ratio, and each bar is labeled with that PC's percentage. `cum=True` draws a cumulative curve instead of per-PC bars, `log=True` uses a log Y axis.

###### `plot_pca(...)`

```python
plot_pca(path=None, *, color=None, components="1,2", dot_size=None,
         width=None, height=None, return_bytes=False)
```

PC scatter: the two components named by `components` become the X / Y axes (1-based, exactly two required), colored by the `obs` column named in `color`; with `color=None` it prefers `obs["batch"]`, and if there is no batch column it draws single-color gray points.

###### `plot_pca_loadings(...)`

```python
plot_pca_loadings(path=None, *, components="1", n_top=30, include_lowest=False,
                  width=None, height=None, return_bytes=False)
```

Loadings plot: one horizontal bar chart per PC showing the `n_top` genes with the largest absolute loading; `include_lowest=True` additionally draws the genes with the lowest loadings in the tail.

###### `plot_cluster_scatter(...)`

```python
plot_cluster_scatter(path=None, *, res_key="leiden", title=None, x_label=None, y_label=None,
                     dot_size=None, width=None, height=None, show_plotting_scale=None,
                     plotting_scale_width=None, reorganize_coordinate=None,
                     horizontal_offset_additional=0.0, vertical_offset_additional=0.0,
                     split_by_batch=True, return_bytes=False)
```

Spatial clustering plot: scatters points at their `position` and colors them with a discrete palette by the cluster column (default `obs["leiden"]`), one color and one legend entry per cluster. With `split_by_batch=True` (the default) multi-sample data splits into subplots; `False` overlays everything in a single plot. `show_plotting_scale` controls whether a physical scale bar is overlaid.

###### `plot_annotation_scatter(...)`

```python
plot_annotation_scatter(labels=None, path=None, *, title=None, x_label=None, y_label=None,
                        dot_size=None, width=None, height=None, show_plotting_scale=None,
                        plotting_scale_width=None, reorganize_coordinate=None,
                        horizontal_offset_additional=0.0, vertical_offset_additional=0.0,
                        split_by_batch=True, return_bytes=False)
```

Spatial annotation plot: the same rendering as `plot_cluster_scatter`, except the coloring is by **cell type label** instead of cluster ID. With `labels=None` it reads the per-cell result of `singler()` (`result.annotation.final_labels`).

###### `plot_ora_dotplot(...)`

```python
plot_ora_dotplot(db_name, path=None, *, cluster_id=None, top_n=15, title=None,
                 width=None, height=None, return_bytes=False)
```

ORA dot plot: the X axis is GeneRatio, dot size is the hit gene count, color is `-log10(p.adj)`. GO results are split into BP/CC/MF sections; KEGG / Reactome (no category) use a single-section zebra-striped table. `cluster_id=None` picks the **first cluster that has any term**.

`db_name` is the **required** first argument naming which library to plot — `"go"`, `"kegg"` or `"reactome"`, i.e. the key assigned by `read_go_db` / `read_kegg_db` / `read_reactome_db`. Results are stored per library and are never overwritten across `run_ora` calls, so each library is plotted separately.

###### `plot_ora_barplot(...)`

```python
plot_ora_barplot(db_name, path=None, *, cluster_id=None, top_n=15, title=None,
                 width=None, height=None, return_bytes=False)
```

ORA bar plot: bar length is the overlap count, bar color is `-log10(p.adj)`. Sectioning follows `plot_ora_dotplot`; rows are ordered by significance (most significant on top).

###### `plot_gsea_enrichment(...)`

```python
plot_gsea_enrichment(db_name, path=None, *, cluster_id=None, term_index=0, title=None,
                     width=None, height=None, return_bytes=False)
```

Classic single-pathway GSEA curve: the upper panel is the running-sum enrichment trace and the lower panel is the hits barcode. `term_index` selects which result of that cluster to draw (0 = most significant).

###### `plot_gsea_dotplot(...)`

```python
plot_gsea_dotplot(db_name, path=None, *, cluster_id=None, top_n=15, title=None,
                  width=None, height=None, return_bytes=False)
```

GSEA dot plot: the X axis is NES (symmetric about 0, left = down-regulated in this cluster, right = up-regulated), dot size is the gene set size K present in the ranked list, color is `-log10(p.adj)`.

###### `plot_gsea_barplot(...)`

```python
plot_gsea_barplot(db_name, path=None, *, cluster_id=None, top_n=15, title=None,
                  width=None, height=None, return_bytes=False)
```

GSEA bar plot: bars extend from the zero line in both directions (NES > 0 to the right, NES < 0 to the left), bar color is `-log10(p.adj)`.
