#!/usr/bin/env nextflow

params.refs = "data/*/*.fasta.gz"
params.qrys = "data/*/*.fasta.gz"

refs = Channel.fromPath(params.refs).map{[it.getParent().getBaseName(), it]}
qrys = Channel.fromPath(params.qrys).map{[it.getParent().getBaseName(), it]}

refs
.tap { genomes1 }
.combine(qrys)
.filter{ it[0] != it[2] }
.tap { genomePairs }

process makeGenomeFiles {
  tag { id }

  input:
  set id, "genome.fasta.gz" from genomes1

  output:
  set id, "genome.fasta.fai" into genomeFiles

  """
zcat genome.fasta.gz > genome.fasta
samtools faidx genome.fasta
  """
}

process nucmer {
  tag { "${idR} vs ${idQ}" }

  input:
  set idR, "ref.fasta.gz", idQ, "qry.fasta.gz" from genomePairs

  output:
  set idR, idQ, val("raw"), "out.delta" into rawDeltas
  set idR, idQ, val("filtered"), "filtered.delta" into fltDeltas

  """
zcat ref.fasta.gz > ref.fasta
zcat qry.fasta.gz > qry.fasta
nucmer --maxmatch ref.fasta qry.fasta
delta-filter -1 out.delta > filtered.delta
  """
}

process showcoords {
  tag { "${idR} vs ${idQ}" }

  input:
  set idR, idQ, type, "in.delta" from rawDeltas.mix(fltDeltas)

  output:
  set idR, idQ, "out.bed" into rawBed

"""
show-coords -T in.delta \
 | tail -n +5 \
 | awk 'BEGIN{OFS="\\t"} {print(\$8, \$1-1, \$2, ".", "+", \$7)}' \
 | sort -k1,1 -k2,2n \
 | bedtools merge -i - \
 | sed 's/\$/\\t$type/g' \
 > out.bed
"""
}

process genomeCoverage {
  tag { "${idR} vs ${idQ}" }

  input:
  set idR, idQ, "in.bed", "in.genome" from rawBed.combine(genomeFiles, by: 0)

  output:
  set idR, idQ, "out.txt" into genomeCoverages

  """
sed 's/\$/\\t$idQ/g' in.bed > out.txt
awk 'BEGIN{OFS="\\t"} {print(\$1, 0, \$2, "base", "$idQ")}' in.genome >> out.txt
  """
}

genomeCoverages
.groupTuple()
.set { plottingInputs }

process plotCoverages {
  publishDir "output", mode: "copy", overwrite: true
  tag { "${idR}"}

  input:
  set idR, queryIDs, "matches.*.txt" from plottingInputs

  output:
  file("${idR}.svg") into outputSVGs

  """
#!/usr/bin/env Rscript

library(readr)
library(dplyr)
library(ggplot2)
library(magrittr)

list.files(".", "matches.*.txt") %>%
  lapply(read_tsv, col_names = c("seqid", "start", "stop", "type", "query"))  %>%
  do.call(what=rbind) -> data

data %>%
  filter(type == "base") %>%
  ggplot(aes(x = query, y=start + (stop-start)/2, height=(stop-start))) +
  geom_tile(fill="white") +
  geom_tile(data=filter(data, type == "raw"), fill="#E6A0C4") +
  geom_tile(data=filter(data, type == "filtered"), fill="#7294D4") +
  theme_minimal() +
  facet_grid(. ~ seqid) +
  theme(axis.text.x = element_text(angle = 90),
        axis.title.y=element_blank()) -> plot

  ggsave(filename="${idR}.svg", plot=plot, width=40)
  """
}

outputSVGs.println()
