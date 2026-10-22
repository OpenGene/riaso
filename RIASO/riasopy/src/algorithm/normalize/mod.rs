pub mod log1p;
pub mod normalize_total;
pub mod scale;

pub use log1p::{log1p, LOG1P_LAYER};
pub use normalize_total::{normalize_total, NORMALIZE_TOTAL_LAYER};
pub use scale::{scale, SCALE_LAYER};

use crate::core::SoData;

fn save_layer(data: &mut SoData, name: &str) {
    if data.layers.contains_key(name) {
        return;
    }
    if let Some(exp) = &data.exp_matrix {
        data.layers.insert(name.to_string(), exp.clone());
    }
}
