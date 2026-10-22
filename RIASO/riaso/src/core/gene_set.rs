use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct GeneSet {
    pub id: String,

    pub name: String,

    pub category: Option<String>,

    pub genes: HashSet<String>,
}

#[derive(Debug, Clone)]
pub struct GeneSetDb {
    pub name: String,

    pub sets: HashMap<String, GeneSet>,

    aliases: HashMap<String, String>,
}

impl GeneSetDb {
    pub fn new(
        name: &str,
        sets: HashMap<String, GeneSet>,
        aliases: HashMap<String, String>,
    ) -> Self {
        GeneSetDb {
            name: name.to_string(),
            sets,
            aliases,
        }
    }

    pub fn resolve(&self, token: &str) -> Option<&str> {
        self.aliases
            .get(&token.to_ascii_lowercase())
            .map(|s| s.as_str())
    }

    pub fn n_sets(&self) -> usize {
        self.sets.len()
    }
}
