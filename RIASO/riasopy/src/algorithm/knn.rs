use crate::algorithm::rng::SplitMix64;
use ndarray::Array2;
use rayon::prelude::*;

pub const DENSE_KNN_THRESHOLD: usize = 8192;

const MAX_ITERS: usize = 30;

const DELTA: f64 = 1e-3;

const N_RP_TREES: usize = 8;

const LEAF_SIZE: usize = 15;

const MAX_CANDIDATES_MULT: usize = 5;

const SEED: u64 = 0;

#[inline]
fn mix(a: u64, b: u64, c: u64) -> u64 {
    let mut z = a ^ b.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ c.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 30)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

#[inline]
fn sqdist(x: &Array2<f64>, i: usize, j: usize) -> f64 {
    let d = x.ncols();
    let mut s = 0.0f64;
    for c in 0..d {
        let a = x[[i, c]] - x[[j, c]];
        s += a * a;
    }
    s
}

pub fn nn_descent_knn(x: &Array2<f64>, k: usize) -> (Array2<i64>, Array2<f64>) {
    let n = x.nrows();
    debug_assert!(k <= n, "nn_descent_knn: k={k} > n={n}");
    if k >= n {
        return exact_all(x, k);
    }
    let max_candidates = k * MAX_CANDIDATES_MULT;
    let init_random_sample = max_candidates;

    let mut rng = SplitMix64::new(SEED);
    let forest = build_forest(x, N_RP_TREES, LEAF_SIZE, &mut rng);

    let mut graph: Vec<Vec<usize>> = (0..n)
        .into_par_iter()
        .map(|i| {
            let mut cands: Vec<usize> = vec![i];
            for tree in &forest {
                for leaf in tree {
                    if leaf.contains(&i) {
                        cands.extend(leaf.iter().copied().filter(|&j| j != i));
                    }
                }
            }
            let mut r = SplitMix64::new(mix(SEED, i as u64, 0));
            for _ in 0..init_random_sample {
                cands.push(r.next_index(n));
            }
            select_knn(x, i, cands, k, &mut r)
        })
        .collect();

    for iter in 1..=MAX_ITERS {
        let candidates: Vec<Vec<usize>> = (0..n)
            .into_par_iter()
            .map(|i| gather_candidates(i, &graph, k, n, max_candidates, SEED, iter as u64))
            .collect();

        let n_changed: usize = graph
            .par_iter_mut()
            .enumerate()
            .map(|(i, g)| {
                let mut r = SplitMix64::new(mix(SEED, i as u64, iter as u64));
                let new_g = select_knn(x, i, candidates[i].clone(), k, &mut r);
                let changed = k - intersection_size(g, &new_g);
                *g = new_g;
                changed
            })
            .sum();

        let frac = n_changed as f64 / (n * k) as f64;
        if frac <= DELTA {
            break;
        }
    }

    let mut idx = Array2::<i64>::zeros((n, k));
    let mut dists = Array2::<f64>::zeros((n, k));
    for i in 0..n {
        for (c, &j) in graph[i].iter().enumerate() {
            idx[[i, c]] = j as i64;
            dists[[i, c]] = sqdist(x, i, j).sqrt();
        }
    }
    (idx, dists)
}

fn gather_candidates(
    i: usize,
    graph: &[Vec<usize>],
    k: usize,
    n: usize,
    max_candidates: usize,
    seed: u64,
    iter: u64,
) -> Vec<usize> {
    let mut cands: Vec<usize> = Vec::with_capacity(k + k * k + max_candidates);
    cands.extend_from_slice(&graph[i]);
    for &j in &graph[i] {
        cands.extend_from_slice(&graph[j]);
    }
    let mut r = SplitMix64::new(mix(seed, i as u64, iter));
    for _ in 0..max_candidates {
        cands.push(r.next_index(n));
    }
    cands
}

fn select_knn(
    x: &Array2<f64>,
    i: usize,
    cands: Vec<usize>,
    k: usize,
    rng: &mut SplitMix64,
) -> Vec<usize> {
    let n = x.nrows();
    let mut uniq: Vec<usize> = Vec::with_capacity(cands.len() + 1);
    uniq.push(i);
    for &j in &cands {
        if j != i && !uniq.contains(&j) {
            uniq.push(j);
        }
    }

    while uniq.len() < k {
        let j = rng.next_index(n);
        if !uniq.contains(&j) {
            uniq.push(j);
        }
    }

    let mut entries: Vec<(usize, f64)> = uniq
        .iter()
        .map(|&j| (j, if j == i { 0.0 } else { sqdist(x, i, j) }))
        .collect();
    entries.select_nth_unstable_by(k - 1, |a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)));
    entries.truncate(k);
    entries.sort_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)));
    entries.into_iter().map(|(j, _)| j).collect()
}

#[inline]
fn intersection_size(a: &[usize], b: &[usize]) -> usize {
    a.iter().filter(|x| b.contains(x)).count()
}

fn exact_all(x: &Array2<f64>, k: usize) -> (Array2<i64>, Array2<f64>) {
    let n = x.nrows();
    let mut idx = Array2::<i64>::zeros((n, k));
    let mut dists = Array2::<f64>::zeros((n, k));
    for i in 0..n {
        let mut entries: Vec<(usize, f64)> = (0..n)
            .map(|j| (j, if j == i { 0.0 } else { sqdist(x, i, j) }))
            .collect();
        entries.sort_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)));
        for (c, &(j, d)) in entries.iter().take(k).enumerate() {
            idx[[i, c]] = j as i64;
            dists[[i, c]] = d.sqrt();
        }
    }
    (idx, dists)
}

fn build_forest(
    x: &Array2<f64>,
    n_trees: usize,
    leaf_size: usize,
    rng: &mut SplitMix64,
) -> Vec<Vec<Vec<usize>>> {
    let n = x.nrows();
    let all: Vec<usize> = (0..n).collect();
    let mut forest = Vec::with_capacity(n_trees);
    for _ in 0..n_trees {
        let mut tree = Vec::new();
        build_tree(x, &all, leaf_size, rng, &mut tree);
        forest.push(tree);
    }
    forest
}

fn build_tree(
    x: &Array2<f64>,
    node: &[usize],
    leaf_size: usize,
    rng: &mut SplitMix64,
    out: &mut Vec<Vec<usize>>,
) {
    if node.len() <= leaf_size {
        out.push(node.to_vec());
        return;
    }
    let (left, right) = hyperplane_split(x, node, rng);
    build_tree(x, &left, leaf_size, rng, out);
    build_tree(x, &right, leaf_size, rng, out);
}

fn hyperplane_split(
    x: &Array2<f64>,
    node: &[usize],
    rng: &mut SplitMix64,
) -> (Vec<usize>, Vec<usize>) {
    let a = node[rng.next_index(node.len())];
    let mut b = node[rng.next_index(node.len())];
    let mut guard = 0;
    while b == a && guard < 8 {
        b = node[rng.next_index(node.len())];
        guard += 1;
    }
    if b == a {
        let mid = node.len() / 2;
        return (node[..mid].to_vec(), node[mid..].to_vec());
    }

    let d = x.ncols();
    let mut left = Vec::with_capacity(node.len() / 2 + 1);
    let mut right = Vec::with_capacity(node.len() / 2 + 1);
    for &p in node {
        let mut s = 0.0f64;
        for c in 0..d {
            s += (x[[p, c]] - x[[a, c]]) * (x[[b, c]] - x[[a, c]]);
        }
        if s < 0.0 {
            left.push(p);
        } else {
            right.push(p);
        }
    }
    if left.is_empty() || right.is_empty() {
        let mid = node.len() / 2;
        left = node[..mid].to_vec();
        right = node[mid..].to_vec();
    }
    (left, right)
}
