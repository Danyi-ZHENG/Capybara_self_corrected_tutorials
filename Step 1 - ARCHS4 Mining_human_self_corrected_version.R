###############################################
# Step 1: ARCHS4 Mining
###############################################

library(rhdf5)

destination_file = "human_matrix_v11.h5"
url = "https://s3.amazonaws.com/mssm-seq-matrix/human_matrix_v11.h5"

#Check if gene expression file was already downloaded, if not in current directory download file form repository
if(!file.exists(destination_file)){
  print("Downloading compressed gene expression matrix.")
  download.file(url, destination_file, quiet = FALSE, mode = 'wb')
}

# Get the meta data from the h5 file
samples = h5read(destination_file, "meta")

sample_meta <- data.frame(channel_count = samples$samples$channel_count, 
                          accession = samples$samples$geo_accession, 
                          characteristics = samples$samples$characteristics_ch1, 
                          organism = samples$samples$organism_ch1, 
                          source = samples$samples$source_name_ch1, 
                          molecule_info = samples$samples$molecule_ch1, 
                          series_id = samples$samples$series_id, stringsAsFactors=F)

# Use only total RNA and polyA RNA-seq data
total.RNA.indx <- which(sample_meta$molecule_info == "total RNA")
poly.A.indx <- which(sample_meta$molecule_info == "polyA RNA")
sample_meta_pa_total <- sample_meta[c(total.RNA.indx, poly.A.indx),]

### Clean some of the labels
sample_meta_pa_total$source[which(tolower(sample_meta_pa_total$source) %in% c("stomachs", "stomach wt", "stomach tissue"))] <- "stomach"
sample_meta_pa_total$source[which(tolower(sample_meta_pa_total$source) %in% c("mus musculus strain c57bl/6j urinary bladder tissue adult (8 weeks)", "bladder"))] <- "urinary bladder"
sample_meta_pa_total$source[which(tolower(sample_meta_pa_total$source) %in% c("bone lining cells", "wild type_calvarial frontal bone", "wild type_calvarial parietal bone",  "wt mandibular bone"))] <- "bone"
sample_meta_pa_total$source[which(tolower(sample_meta_pa_total$source) %in% c("primary esophagus"))] <- "esophagus"

# Limit to these tissue labels
tissue.to.choose <- c("aorta", "bone", "bone marrow", "marrow", "brain", "colon", 
                      "large intestine", "diaphragm", "embryo", "esophagus", "brown fat", "white fat", 
                      "adipose", "gall bladder", "heart", "kidney", "lung", "ovary", 
                      "pancreas", "prostate", "skin", "small intestine", "spleen", "muscle", 
                      "stomach", "testis", "thymus", "tongue", "trachea", 
                      "urinary bladder", "uterus", "liver", "mammary gland")
indx <- which(tolower(sample_meta_pa_total$source) %in% tissue.to.choose)

sample_tissue_sub <- sample_meta_pa_total[indx,]
sample_tissue_sub$source <- tolower(sample_tissue_sub$source)

# Get the strain infomation in place
strains <- c()
treatment <- c()
genotype <- c()
for (i in 1:nrow(sample_tissue_sub)) {
  curr_characteristics <- sample_tissue_sub$characteristics[i]
  curr_parts <- strsplit(curr_characteristics, "Xx-xX")[[1]]
  strain.parts <- which(startsWith(tolower(curr_parts), "strain"))
  treatment.parts <- which(startsWith(tolower(curr_parts), "treatment"))
  genotype.parts <- which(startsWith(tolower(curr_parts), "genotype"))
  
  curr_strain <- " "
  curr_treatment <- " "
  curr_genotype <- " "
  if (length(strain.parts) > 0) {
    curr_strain <- strsplit(tolower(curr_parts[strain.parts]), "strain: ")[[1]][2]
  } 
  if (length(treatment.parts) > 0) {
    curr_treatment <- strsplit(tolower(curr_parts[treatment.parts]), "treatment: ")[[1]][2]
  } 
  if (length(genotype.parts) > 0) {
    curr_genotype <- strsplit(tolower(curr_parts[genotype.parts]), "genotype: ")[[1]][2]
  } 
  strains <- c(strains, curr_strain)
  treatment <- c(treatment, curr_treatment)
  genotype <- c(genotype, curr_genotype)
}

# subset to only include c57bl6 (not for human dataset)
sample_tissue_sub$strain <- strains
sample_tissue_sub$treatment <- treatment
sample_tissue_sub$genotype <- genotype

sample_tissue_strain_sub <- sample_tissue_sub
saveRDS(sample_tissue_sub, "01_full_accession_information_data_frame.Rds")

# Retrieve information from compressed data
samples_geo = samples$samples$geo_accession
genes <- samples$genes

sample_locations = which(samples_geo %in% sample_tissue_strain_sub$accession)

# Read the expression data
expression = h5read(destination_file, "data/expression")
expression_sub = expression[1:length(genes$genes),1:length(sample_locations)]
H5close()

rownames(expression_sub) = genes$genes
colnames(expression_sub) = samples_geo[sample_locations]

# Use Ensembl to extract gene length information based on Ensembl ID
library(biomaRt)
gene.info = genes[c("ensembl_gene_id", "gene_symbol")]

mart <- useMart("ensembl",dataset="hsapiens_gene_ensembl")
ensembl.gene <- gene.info$ensembl_gene_id[which(!is.na(gene.info$ensembl_gene_id))]
ensembl.map.rslt <- getBM(attributes = c("hgnc_symbol", "start_position", "end_position", "ensembl_gene_id_version", "external_gene_name", "ensembl_gene_id"), 
                          filters = "ensembl_gene_id", values = ensembl.gene, mart = mart)

ensembl.map.rslt <- unique(ensembl.map.rslt[,c(2:6)])
ensembl.map.rslt = ensembl.map.rslt[-c(6049, 6076),] #(remove two replicate rows, row index might alter)
rownames(ensembl.map.rslt) <- ensembl.map.rslt$ensembl_gene_id  
# Calculate length of the gene    
ensembl.map.rslt$gene.length <- abs(ensembl.map.rslt$end_position - ensembl.map.rslt$start_position)/1000

gene.info$gene.length <- ensembl.map.rslt[gene.info$ensembl_gene_id, "gene.length"]
gene.info = as.data.frame(gene.info)

gene.info.sub <- gene.info[which(!is.na(gene.info$gene.length)),]
rownames(gene.info.sub) <- gene.info.sub$gene_symbol

# RPKM Calculation
raw.count.sub <- expression_sub[which(rownames(expression_sub) %in% gene.info.sub$gene_symbol),]
raw.count.sub <- as.data.frame(raw.count.sub)
raw.count.sub$gene.length <- gene.info.sub[rownames(raw.count.sub), "gene.length"]
rpkm.count <- raw.count.sub[,c(1:(ncol(raw.count.sub) - 1))]
# Calculate per million size factor and divide each sample by its size factor
size.factors <- colSums(raw.count.sub[,c(1:(ncol(raw.count.sub) - 1))])/1000000
for (i in 1:(ncol(rpkm.count))) {
  rpkm.count[,i] <- rpkm.count[,i]/size.factors[colnames(rpkm.count)[i]]
  rpkm.count[,i] <- rpkm.count[,i]/raw.count.sub$gene.length
}

saveRDS(rpkm.count, "03_rpkm_count_Tissue_bulk.Rds")
saveRDS(raw.count.sub[,c(1:(ncol(raw.count.sub) - 1))], "03_raw_count_Tissue_bulk.Rds")
