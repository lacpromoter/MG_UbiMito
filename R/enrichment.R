#' Functional enrichment using Fisher's test
#'
#' @param genes_all - a vector with all feature (gene, protein, etc.) ids (universe)
#' @param genes_sel - a vector with a selection of feature ids
#' @param term_data - term_data: an object with term data, a list with two fields 1) term2gene - a list of vectors, term -> [gene_id1, gene_id1, ...], 2) term - data frame with columns 'term_id' and any other columns with name, description and so on.
#' @param gene2name - a named vector to change feature ids into feature names
#' @param min_count - minimum number of features to consider for a given term; terms with fewer features will be ignored
#' @param sig_limit - significance limit for enriched terms (multiple test corrected)
#'
#' @return A tibble with results.
#' @export
functionalEnrichment <- function(genes_all, genes_sel, term_data, gene2name = NULL,
                                 min_count=3, sig_limit=0.05) {
  
  term2gene <- term_data$term2gene
  term_info <- term_data$terms
  terms <- names(term2gene)
  
  # number of selected genes
  Nsel <- length(genes_sel)
  # size of the universe
  Nuni <- length(genes_all)
  
  # empty line for missing terms
  na_term <- term_info %>% slice(1) %>% mutate_all(~NA)
  
  res <- map_dfr(terms, function(term) {
    # all genes with the term 
    tgenes <- term2gene[[term]]
    # genes from selection with the term
    tgenes_sel <- intersect(tgenes, genes_sel)
    
    nuni <- length(tgenes)
    nsel <- length(tgenes_sel)
    
    g <- NULL
    if(nsel >= min_count) {
      info <- term_info[term_info$term_id == term, ]
      # returns NAs if no term found
      if(nrow(info) == 0) info <- na_term %>% mutate(term_id = term)
      expected <- nuni * Nsel / Nuni
      fish <- matrix(c(nsel, nuni - nsel, Nsel - nsel, Nuni + nsel - Nsel - nuni), nrow=2)
      ft <- fisher.test(fish, alternative = "greater")
      p <- as.numeric(ft$p.value)
      
      if(!is.null(gene2name)) tgenes_sel <- sort(unname(gene2name[tgenes_sel]))
      
      g <- bind_cols(
        info,
        tibble(
          tot = nuni,
          sel = nsel,
          expect = expected,
          enrich = nsel / expected,
          ids = paste(tgenes_sel, collapse=" "),
          P = p
        )
      )
    }
    g
  })
  
  res %>% 
    mutate(P = p.adjust(P, method="BH")) %>% 
    filter(P <= sig_limit) %>% 
    arrange(desc(enrich)) %>% 
    mutate(enrich = round(enrich, 1), expect = round(expect, 2))
}


#' Gene set functional enrichment analysis
#'
#' Performs set enrichment analysis based on a score (e.g., fold-change from
#' differential expression). Gene (or protein, transcript, etc.) sets are
#' defined by functional terms (e.g. GO-terms or pathways).
#'
#' @details
#'
#' Below, we use term "gene" for simplicity. This function can be used on any
#' set of entities, e.g., proteins.
#'
#' Gene set enrichment identifies outstanding sets of genes based on absolute
#' mean score. Each gene has a positive or negative score, e.g., log-fold-change
#' from differential expression. Sets of genes are defined by functional terms,
#' e.g. GO-terms or pathways. For each set the mean score is calculated and
#' compared against the background of scores from randomly sampled (no
#' replacement) sets of genes of the same size, which is done by bootstrapping.
#' The "p-value" is the proportion of absolute mean bootstrap scores greater to
#' the absolute mean set score. The smaller the "p-value" the more statistically
#' outstanding the set is in terms of the absolute score.
#'
#' This function requires three objects for input.
#'
#' 1. A vector of scores. Each gene should have a score.
#'
#' 2. Gene/functional term association.
#'
#' 3. Functional term names or descriptions.
#'
#' See parameter description for details of the data structures above.
#'
#' @param score A named list of scores. Names are gene/protein identifiers.
#' @param term.id A data frame with gene id/functional term association. It
#'   should contain two columns called "id", with gene ID and "term" with term
#'   ID.
#' @param term.name A data frame with functional terms. It should contain
#'   columns "term" with term ID (as in \code{term.id}) and "name" with term
#'   name/description.
#' @param minn Minimum number of set to consider.
#' @param nboot Number of bootstraps.
#' @param ncores Number of cores for parallel processing (not in use at the moment)
#' @param verbose Logical, if TRUE the progress percentage will be displayed.
#'
#' @return A data frame with term enrichment results. The columns are "term" and
#'   "name" for functional term and its description, "p" is the "p-value" and
#'   "M" is the mean score (see above for details), "n" is the size of the set.
#'   Finally, "ids" contains a comma-delimited list of gene IDs included in the
#'   set.
#'   
setEnrichment <- function(score, term.id, term.name, minn=3, nboot=1000, ncores=4, verbose=FALSE) {
  if(!all(c("id", "term") %in% names(term.id))) stop("term.id requires columns id and term.")
  if(!all(c("term", "name") %in% names(term.name))) stop("term.name requires columns term and name.")
  boots <- list()
  term2id <- tapply(term.id$id, term.id$term, identity)
  N <- length(term2id)
  P <- list()
  i <- 1
  if(verbose) cat("      ")
  for(term in names(term2id)) {
    if(verbose & i %% 10 == 0) cat(sprintf("\b\b\b\b\b\b%5.1f%%", 100 * i / N))
    ids <- as.character(term2id[[term]])
    vals <- score[ids]
    n <- length(na.omit(vals))
    if(n >= minn) {
      sn <- as.character(n)   # for list indexing, cannot be integer
      M <- mean(vals, na.rm=TRUE)
      if(is.null(boots[[sn]])) {
        b <- lapply(1:nboot, function(ib) {
          mean(sample(score, n), na.rm=TRUE)
        })
        boots[[sn]] <- unlist(b)
      }
      p <- length(which(abs(boots[[sn]]) > abs(M))) / nboot
      tsel <- which(term.name$term == term)
      if(length(tsel) == 1) {
        name <- term.name[tsel, "name"]
      } else {
        name <- "N/A"
      }
      P[[i]] <- data.frame(
        term = term,
        name = name,
        p = p,
        M = M,
        n = n,
        ids = paste(ids, collapse=",")
      )
    }
    i <- i + 1
  }
  if(verbose) cat("\n")
  res <- do.call(rbind, P)
  return(res)
}



make_term_list <- function(gene2term) {
  gene2term %>%
    arrange(term_id) %>%
    group_split(term_id) %>%
    map(function(w) w$gene_id) %>%
    set_names(unique(gene2term$term_id) %>% sort)  # dodgy!
}

fgsea_run <- function(trm, res, min.size=3, nperm=100000) {
  term_list <-  make_term_list(trm$gene2term %>% filter(gene_id %in% res$gene_id))
  ranks <-  setNames(res$value, res$gene_id)
  fgsea(pathways=term_list, stats=ranks, nperm=nperm, nproc=6, minSize=min.size) %>%
    as_tibble %>%
    left_join(trm$terms, by=c("pathway" = "term_id")) %>%
    arrange(NES) %>% 
    select(term = pathway, term_name, pval, padj, NES, nMoreExtreme, size) 
}


fgsea_cache <- function(str, file) {
  if(file.exists(file)) {
    fg <- readRDS(file)
  } else {
    fg <- str %>% 
      mutate(value = b) %>% 
      group_split(covariate) %>% 
      map_dfr(function(w) {
        fgsea_run(bm_go, w) %>% mutate(covariate = first(w$covariate))
      })
    saveRDS(fg, file)
  }
  fg
}