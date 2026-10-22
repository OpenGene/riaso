use std::collections::HashMap;

use nalgebra_sparse::csr::CsrMatrix;
use ndarray::{Array1, Array2};

#[derive(Debug, Clone)]
pub struct PcaResult {
    pub projected: Array2<f64>,
    pub components: Array2<f64>,
    pub explained_variance: Array1<f64>,
    pub explained_variance_ratio: Array1<f64>,
    pub mean: Array1<f64>,
    pub total_variance: f64,
}

#[derive(Debug, Clone)]
pub struct ClusterMarkerResult {
    pub cluster_id: i64,
    pub gene_indices: Vec<usize>,
    pub t_stats: Vec<f64>,
    pub scores: Vec<f64>,
    pub pvalues: Vec<f64>,
    pub pvalues_adj: Vec<f64>,
    pub log2fc: Vec<f64>,
    pub pct: Vec<f64>,
    pub pct_rest: Vec<f64>,
    pub mean_count: Vec<f64>,
}
#[derive(Debug, Clone)]
pub struct MarkerResult {
    pub clusters: Vec<ClusterMarkerResult>,
}
impl MarkerResult {
    pub fn n_clusters(&self) -> usize {
        self.clusters.len()
    }
}

#[derive(Debug, Clone)]
pub struct HvgResult {
    pub genes: Vec<String>,
    pub means: Vec<f64>,
    pub dispersions: Vec<f64>,
    pub dispersions_norm: Vec<f64>,
    pub highly_variable: Vec<bool>,
}
impl HvgResult {
    pub fn n_genes(&self) -> usize {
        self.means.len()
    }
}

#[derive(Debug, Clone)]
pub struct OraTerm {
    pub id: String,

    pub name: String,

    pub category: Option<String>,

    pub pvalue: f64,

    pub pvalue_adj: f64,

    pub count: usize,

    pub overlap: Vec<String>,

    pub gene_ratio: f64,

    pub bg_ratio: f64,
}

#[derive(Debug, Clone)]
pub struct OraGroupResult {
    pub group_id: i64,
    pub terms: Vec<OraTerm>,
}

#[derive(Debug, Clone)]
pub struct EnrichmentResult {
    pub groups: HashMap<String, Vec<OraGroupResult>>,

    pub gsea: HashMap<String, GseaResult>,
}

#[derive(Debug, Clone)]
pub struct GseaTerm {
    pub id: String,

    pub name: String,

    pub category: Option<String>,

    pub es: f64,

    pub nes: f64,

    pub pvalue: f64,

    pub pvalue_adj: f64,

    pub size: usize,

    pub rank_at_es: usize,

    pub leading_edge: Vec<String>,

    pub running_sum: Vec<(usize, f64)>,

    pub hits: Vec<usize>,
}

#[derive(Debug, Clone)]
pub struct GseaGroupResult {
    pub group_id: i64,
    pub terms: Vec<GseaTerm>,
}

#[derive(Debug, Clone)]
pub struct GseaResult {
    pub groups: Vec<GseaGroupResult>,
}

#[derive(Debug, Clone)]
pub struct BatchCorrectionResult {
    pub corrected: Array2<f64>,
    pub r: Array2<f64>,
    pub n_iter: usize,
    pub converged: bool,
}

#[derive(Debug, Clone)]
pub struct NeighborsResult {
    pub knn_indices: Array2<i64>,
    pub connectivities: CsrMatrix<f64>,
    pub distances: CsrMatrix<f64>,
}

#[derive(Debug, Clone)]
pub struct AnnotationResult {
    pub first_labels: Vec<String>,
    pub final_labels: Vec<String>,
    pub scores: Array2<f64>,
    pub labels: Vec<String>,
    pub clusters: Vec<i64>,
}

#[derive(Debug, Clone)]
pub struct UmapResult {
    pub embedding: Array2<f64>,
}

#[derive(Debug, Clone, Default)]
pub struct AnalysisResults {
    pub pca: Option<PcaResult>,
    pub batch: Option<BatchCorrectionResult>,
    pub neighbors: Option<NeighborsResult>,
    pub umap: Option<UmapResult>,
    pub annotation: Option<AnnotationResult>,
    pub hvg: Option<HvgResult>,
    pub marker: Option<MarkerResult>,
    pub enrichment: Option<EnrichmentResult>,
}
