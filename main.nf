#!/usr/bin/env nextflow

Channel
  .from( file(params.sra_list_path).readLines() )
  .set { SRAs }

Channel
  .fromPath( params.local_samples_path )
  .set { local_SRAs }


process fastq_dump {
  module 'sratoolkit'
  publishDir "$sra", mode: 'link'
  time '24h'
  tag { sra }

  input:
    val sra from SRAs

  output:
    set val(sra), file("${sra}_?.fastq") into raw_fastq
  """
    fastq-dump --split-files $sra
  """
}


process parse_local_sra {

  input:
    val sra_filename from local_SRAs

  output:
    set stdout, val("${sra_filename}") into local_raw_fastq

    """
    #!/usr/bin/python

    import os
    import sys

    base_filename = os.path.basename("$sra_filename")
    srr_name = base_filename.split('_')[0]

    sys.stdout.write(srr_name)
    """
}


combined_fastq = raw_fastq.mix( local_raw_fastq )


/**
 * Performs Trimmomatic on all fastq files.
 *
 * This process requires that the ILLUMINACLIP_PATH environment
 * variable be set in the trimmomatic module. This indicates
 * the path where the clipping files are stored.
 *
 * depends: download
 *
 */
process trimmomatic {
  module "trimmomatic"
  publishDir "$sra", mode: 'link'
  // Trimmomatic can't work with a symlink
  stageInMode "link"
  tag { sra }
  input:
    set val(sra), file("${sra}_?.fastq") from combined_fastq
  output:
    set val(sra), file("${sra}_?.trim.fastq"), file("${sra}_?s.trim.fastq") into trim_fastq
  script:
      """
      if [ -e ${sra}_1.fastq ] && [ -e ${sra}_2.fastq ]; then
        java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
          PE \
          -threads 1 \
          -phred33 \
          ${sra}_1.fastq \
          ${sra}_2.fastq \
          ${sra}_1.trim.fastq \
          ${sra}_1s.trim.fastq \
          ${sra}_2.trim.fastq \
          ${sra}_2s.trim.fastq \
          ILLUMINACLIP:${params.trimmomatic.clip_path}/fasta_adapter.txt:2:40:15 \
          LEADING:3 \
          TRAILING:6 \
          SLIDINGWINDOW:4:15 \
          MINLEN:50
      else
        # For ease of the next steps, rename the reverse file to the forward.
        # since these are non-paired it really shouldn't matter.
        if [ -e ${sra}_2.fastq ]; then
          mv ${sra}_2.fastq ${sra}_1.fastq
        fi
        # Even though this is not paired-end, we need to create the 1s.trim.fastq
        # file as an empty file so that the rest of the workflow works
        touch ${sra}_1s.trim.fastq
        # Now run trimmomatic
        java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
          SE \
          -threads 1 \
          -phred33 \
          ${sra}_1.fastq \
          ${sra}_1.trim.fastq \
          ILLUMINACLIP:${params.trimmomatic.clip_path}/fasta_adapter.txt:2:40:15 \
          LEADING:3 \
          TRAILING:6 \
          SLIDINGWINDOW:4:15 \
          MINLEN:50
      fi
      """
}

/**
 * Performs hisat2 alignment of fastq files to a genome reference
 *
 * depends: trimmomatic
 */
process hisat2 {
  module 'hisat2'
  publishDir "$sra", mode: 'link'
  stageInMode "link"
  tag { sra }
  input:
    set val(sra), file("${sra}_?.trim.fastq"), file("${sra}_?s.trim.fastq") from trim_fastq
  output:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.sam") into sam_files

  script:
    """
      export HISAT2_INDEXES=${params.ref.path}
      if [ -e ${sra}_2.trim.fastq ]; then
        hisat2 \
          -x ${params.ref.prefix} \
          --no-spliced-alignment \
          -q \
          -1 ${sra}_1.trim.fastq \
          -2 ${sra}_2.trim.fastq \
          -U ${sra}_1s.trim.fastq,${sra}_2s.trim.fastq \
          -S ${sra}_vs_${params.ref.prefix}.sam \
          -t \
          -p 1 \
          --dta-cufflinks
      else
        hisat2 \
          -x ${params.ref.prefix} \
          --no-spliced-alignment \
          -q \
          -U ${sra}_1.trim.fastq \
          -S ${sra}_vs_${params.ref.prefix}.sam \
          -t \
          -p 1 \
          --dta-cufflinks
      fi
    """
}


/**
 * Sorts the SAM alignment file and coverts it to binary BAM
 *
 * depends: hisat2
 */
process samtools_sort {
  module 'samtools'
  publishDir "$sra", mode: 'link'
  stageInMode "link"
  tag { sra }

  input:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.sam") from sam_files
  output:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.bam") into bam4index, bam4stringtie
  script:
    """
    samtools sort -o ${sra}_vs_${params.ref.prefix}.bam -O bam ${sra}_vs_${params.ref.prefix}.sam
    """
}

/**
 * Indexes the BAM alignment file
 *
 * depends: samtools_index
 */
process samtools_index {
  module 'samtools'
  publishDir "$sra", mode: 'link'
  stageInMode "link"
  tag { sra }
  input:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.bam") from bam4index
  output:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.bam"), file("${sra}_vs_${params.ref.prefix}.bam.bai") into bambai4stringtie
  script:
    """
    samtools index ${sra}_vs_${params.ref.prefix}.bam
    """
}

/**
 * Generates expression-level transcript abundance
 *
 * depends: samtools_index
 */
process stringtie {
  module 'stringtie'
  publishDir "$sra", mode: 'link'
  stageInMode "link"
  tag { sra }

  input:
    // We don't really need the .bai file, but we want to ensure
    // this process runs after the samtools_index step so we
    // require it as an input file.
    set val(sra), file("${sra}_vs_${params.ref.prefix}.bam"), file("${sra}_vs_${params.ref.prefix}.bam.bai") from bambai4stringtie

  output:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.gtf") into stringtie_gtfs
  script:
    """
    stringtie -v -p 1 -e -G ${params.ref.path}/${params.ref.prefix}.gtf -o ${sra}_vs_${params.ref.prefix}.gtf -l ${sra} ${sra}_vs_${params.ref.prefix}.bam
    """
}

/**
 * Generates the final FPKM file
 */
process fpkm {
  publishDir "$sra", mode: 'link'
  stageInMode "link"
  tag { sra }
  input:
    set val(sra), file("${sra}_vs_${params.ref.prefix}.gtf") from stringtie_gtfs
  output:
    file "${sra}_vs_${params.ref.prefix}.fpkm" into fpkms
  script:
    """
    ${PWD}/scripts/gtf2fpkm.sh ${sra} ${params.ref.prefix}
    """
}
