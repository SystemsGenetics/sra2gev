#!/usr/bin/env nextflow

/**
 * ========
 * GEMmaker
 * ========
 *
 * Authors:
 *  + John Hadish
 *  + Tyler Biggs
 *  + Stephen Ficklin
 *  + Ben Shealy
 *  + Connor Wytko
 *
 * Summary:
 *   A workflow for processing a large amount of RNA-seq data
 */



println """\

===================================
 G E M M A K E R   P I P E L I N E
===================================

General Information:
--------------------
  Profile(s):         ${workflow.profile}
  Container Engine:   ${workflow.containerEngine}


Input Parameters:
-----------------
  Remote fastq list path:     ${params.input.remote_list_path}
  Local sample glob:          ${params.input.local_samples_path}
  Reference genome path:      ${params.input.reference_path}
  Reference genome prefix:    ${params.input.reference_prefix}


Output Parameters:
------------------
  Output directory:           ${params.output.dir}
  Publish mode:               ${params.output.publish_mode}
  Publish trimmed FASTQ:      ${params.output.publish_trimmed_fastq}
  Publish BAM:                ${params.output.publish_bam}
  Publish FPKM:               ${params.output.publish_fpkm}
  Publish TPM:                ${params.output.publish_tpm}


Execution Parameters:
---------------------
  Queue size:                 ${params.execution.queue_size}
  Number of threads:          ${params.execution.threads}
  Maximum retries:            ${params.execution.max_retries}
  Error strategy:             ${params.execution.error_strategy}


Software Parameters:
--------------------
  Trimmomatic clip path:      ${params.software.trimmomatic.clip_path}
  Trimmomatic minimum ratio:  ${params.software.trimmomatic.MINLEN}
"""



/**
 * Create value channels that can be reused
 */
HISAT2_INDEXES = Channel.fromPath("${params.input.reference_path}/${params.input.reference_prefix}*.ht2*").collect()
SALMON_INDEXES = Channel.fromPath("${params.input.reference_path}/${params.input.reference_prefix}*").collect()
GTF_FILE = Channel.fromPath("${params.input.reference_path}/${params.input.reference_prefix}.gtf").collect()



/**
 * Local Sample Input.
 * This checks the folder that the user has given
 */
if (params.input.local_samples_path == "none") {
  Channel.empty().set { LOCAL_SAMPLES_FILES_FOR_BATCHING }
}
else {
  Channel.fromFilePairs( params.input.local_samples_path, size: -1 )
    .set { LOCAL_SAMPLE_FILES_FOR_BATCHING }
  Channel.fromFilePairs( params.input.local_samples_path, size: -1 )
    .set { LOCAL_SAMPLE_FILES_FOR_JOIN }
}

/**
 * Remote fastq_run_id Input.
 */
if (params.input.remote_list_path == "none") {
  Channel.empty().set { SRR_FILE }
}
else {
  Channel.value(params.input.remote_list_path).set { SRR_FILE }
}


/**
 * Set the pattern for publishing downloaded files
 */
publish_pattern_fastq_dump = "{none}";
if (params.output.publish_downloaded_fastq == true) {
  publish_pattern_fastq_dump = "{*.fastq}";
}



/**
 * Set the pattern for publishing trimmed files
 */
publish_pattern_trimmomatic = "{*.trim.log}";
if (params.output.publish_trimmed_fastq == true) {
  publish_pattern_trimmomatic = "{*.trim.log,*_trim.fastq}";
}



/**
 * Set the pattern for publishing BAM files
 */
publish_pattern_samtools_sort = "{*.log}";
publish_pattern_samtools_index = "{*.log}";

if (params.output.publish_bam == true) {
  publish_pattern_samtools_sort = "{*.log,*.bam}";
  publish_pattern_samtools_index = "{*.log,*.bam.bai}";
}


/**
 * Retrieves metadata for all of the remote samples
 * and maps SRA runs to SRA experiments.
 */
process retrieve_sample_metadata {
  publishDir params.output.dir, mode: params.output.publish_mode, pattern: "*.GEMmaker.meta.*", saveAs: { "${it.tokenize(".")[0]}/${it}" }
  label "python3"

  input:
    val srr_file from SRR_FILE

  output:
    stdout SRR2SRX_FOR_BATCHING
    file "*.GEMmaker.meta.*"

  script:
    """
    retrieve_SRA_metadata.py $srr_file
    """
}

/**
 * Splits the SRR2XRX mapping file for ensuring batches of samples
 * process together to help conserve space
 */

// First create a list of the remote and local samples
SRR2SRX_FOR_BATCHING
  .splitCsv()
  .groupTuple(by: 1)
  .map { [it[1], it[0].toString().replaceAll(/[\[\]\'\,]/,''), 'remote'] }
  .set{REMOTE_SAMPLES_FOR_BATCHING}

LOCAL_SAMPLE_FILES_FOR_BATCHING
  .map{ [it[0], it[1], 'local' ] }
  .set{LOCAL_SAMPLES_FOR_BATCHING}

// Create the channels needed for batching of samples
BATCHES = REMOTE_SAMPLES_FOR_BATCHING
  .mix(LOCAL_SAMPLES_FOR_BATCHING)
  .collate(params.execution.queue_size)

// Create the directories we'll use for running
// batches
file('work/GEMmaker').mkdir()
file('work/GEMmaker/stage').mkdir()
file('work/GEMmaker/process').mkdir()

// Clean up any files left over from a previous run.
existing_files = file('work/GEMmaker/stage/*')
for (existing_file in existing_files) {
  existing_file.delete()
}
existing_files = file('work/GEMmaker/process/*')
for (existing_file in existing_files) {
  existing_file.delete()
}

/**
 * Writes the batch files and stores them in the
 * stage directory.
 */
process write_batch_files {
  executor "local"
  cache false

  input:
    val batch from BATCHES

  output: 
    val (1) into BATCHES_READY_SIGNAL

  exec: 
    // First create a file for each batch of samples.  We will
    // process the batches one at a time.  
    num_files = file('work/GEMmaker/stage/BATCH.*').size()
    batch_file = file('work/GEMmaker/stage/BATCH.' + num_files)
    batch_file.withWriter {
      for (item in batch) {
        sample = item[0]
        type = item[2]
        if (type.equals('local')) {
          if (item[1].size() > 1) {
            files = item[1]
            files_str = files.join('::')
            it.writeLine '"' + sample + '","' + files_str + '","' + type + '"'
          }
          else {
            it.writeLine '"' + sample + '","' + item[1].first().toString() + '","' + type + '"'
          }
        }
        else {
          it.writeLine '"' + sample + '","' + item[1] + '","' + type + '"'
        }
      }
    }
}

// When all batch files are created we need to then
// move the first file into the process directory.
BATCHES_READY_SIGNAL.collect().set { FIRST_BATCH_START_SIGNAL }

/**
 * Moves the first batch file into the process directory.
 */
process start_first_batch {
  executor "local"
  cache false

  input:
    val signal from FIRST_BATCH_START_SIGNAL
   
  exec:
    // Move the first batch file into the processing direcotry
    // so that we jumpstart the workflow.
    batch_files = file('work/GEMmaker/stage/BATCH.*');
    batch_files.first().moveTo('work/GEMmaker/process')
}

// Create the channel that will watch the process directory
// for new files. When a new batch file is added 
// it will be read and its samples sent through the
// workflow.
NEXT_BATCH = Channel
   .watchPath('work/GEMmaker/process')

/**
 * Opens the batch file and prints it's conents to
 * STDOUT so that the samples can be caught in a new
 * channel and start processing.
 */
process read_batch_file {
  executor "local"
  tag { batch_file }
  cache false
    
  input:
    file(batch_file) from NEXT_BATCH

  output:
    stdout BATCH_FILE_CONTENTS

  script:
    // If this is our last batch then close the open
    // channels that perform our looping or we'll hang.
    batch_files = file('work/GEMmaker/stage/BATCH.*');
    if (batch_files.size() == 0) {
      NEXT_BATCH.close()
      HISAT2_SAMPLE_COMPLETE_SIGNAL.close()
      KALLISTO_SAMPLE_COMPLETE_SIGNAL.close()
      SALMON_SAMPLE_COMPLETE_SIGNAL.close()
      SAMPLE_COMPLETE_SIGNAL.close()
    }
    """
      cat $batch_file
    """
}

// Split our batch file contents into two different
// channels, one for remote samples and another for local.
LOCAL_SAMPLES = Channel.create()
REMOTE_SAMPLES = Channel.create()
BATCH_FILE_CONTENTS
  .splitCsv(quote: '"')
  .choice(LOCAL_SAMPLES, REMOTE_SAMPLES) { a -> a[2] =~ /local/ ? 0 : 1 } 

// Split our list of local samples into two pathways, onefor
// FastQC analysis and the other for read counting.  We don't
// do this for remote samples because they need downloading
// first.
LOCAL_SAMPLES
  .map {[it[0], 'hi']}
  .mix(LOCAL_SAMPLE_FILES_FOR_JOIN)
  .groupTuple(size: 2)
  .map {[it[0], it[1][0]]}
  .into {LOCAL_SAMPLES_FOR_FASTQC_1; LOCAL_SAMPLES_FOR_COUNTING}


// Create the channels needed for signalling when
// samples are completed.
HISAT2_SAMPLE_COMPLETE_SIGNAL = Channel.create()
KALLISTO_SAMPLE_COMPLETE_SIGNAL = Channel.create()
SALMON_SAMPLE_COMPLETE_SIGNAL = Channel.create()

// Create the channel that will collate all the signals
// and release a signal when the batch is complete
SAMPLE_COMPLETE_SIGNAL = Channel.create()
SAMPLE_COMPLETE_SIGNAL
  .mix(HISAT2_SAMPLE_COMPLETE_SIGNAL, KALLISTO_SAMPLE_COMPLETE_SIGNAL, SALMON_SAMPLE_COMPLETE_SIGNAL)
  .collate(params.execution.queue_size, false)
  .set { BATCH_DONE_SIGNAL }

/**
 * Handles the end of a batch by moving a new batch
 * file into the process directory which triggers
 * the NEXT_BATCH.watchPath channel.
 */
process next_batch {
  executor "local"

  input:
    val signal from BATCH_DONE_SIGNAL

  exec:
    // Move the first batch file into the processing direcotry
    // so that we jumpstart the workflow.
    batch_files = file('work/GEMmaker/stage/BATCH.*');
    if (batch_files.size() > 0) {
      batch_files.first().moveTo('work/GEMmaker/process')
    }
    else {
    }
}

/**
 * Downloads FASTQ files from the NCBI SRA.
 */
process fastq_dump {
  publishDir params.output.dir, mode: params.output.publish_mode, pattern: publish_pattern_fastq_dump, saveAs: { "${exp_id}/${it}" }
  tag { exp_id }
  label "sratoolkit"
  label "retry"

  input:
    set val(exp_id), val(run_ids), val(type) from REMOTE_SAMPLES

  output:
    set val(exp_id), file("*.fastq") into DOWNLOADED_FASTQ_FOR_COMBINATION
    set val(exp_id), file("*.fastq") into DOWNLOADED_FASTQ_FOR_CLEANING

  script:
  """
  ids=`echo $run_ids | perl -p -e 's/[\\[,\\]]//g'`
  for run_id in \$ids; do
    fastq-dump --split-files \$run_id
  done
  """
}



/**
 * This process merges the fastq files based on their sample_id number.
 */
process SRR_combine {
  tag { sample_id }

  input:
    set val(sample_id), file(grouped) from DOWNLOADED_FASTQ_FOR_COMBINATION

  output:
    set val(sample_id), file("${sample_id}_?.fastq") into MERGED_SAMPLES_FOR_COUNTING
    set val(sample_id), file("${sample_id}_?.fastq") into MERGED_SAMPLES_FOR_FASTQC_1
    set val(sample_id), file("${sample_id}_?.fastq") into MERGED_FASTQ_FOR_CLEANING
    set val(sample_id), val(1) into CLEAN_DOWNLOADED_FASTQ_SIGNAL

  /**
   * This command tests to see if ls produces a 0 or not by checking
   * its standard out. We do not use a "if [-e *foo]" becuase it gets
   * confused if there are more than one things returned by the wildcard
   */
  script:
  """
    if ls *_1.fastq >/dev/null 2>&1; then
      cat *_1.fastq >> "${sample_id}_1.fastq"
    fi

    if ls *_2.fastq >/dev/null 2>&1; then
      cat *_2.fastq >> "${sample_id}_2.fastq"
    fi
  """
}



/**
 * This is where we combine samples from both local and remote sources.
 */
COMBINED_SAMPLES_FOR_FASTQC_1 = LOCAL_SAMPLES_FOR_FASTQC_1.mix(MERGED_SAMPLES_FOR_FASTQC_1)
COMBINED_SAMPLES_FOR_COUNTING = LOCAL_SAMPLES_FOR_COUNTING.mix(MERGED_SAMPLES_FOR_COUNTING)

/**
 * Performs fastqc on raw fastq files 
 */
process fastqc_1 {
  publishDir params.output.sample_dir, mode: params.output.publish_mode, pattern: "*_fastqc.*"
  tag { sample_id }
  label "fastqc"

  input:
    set val(sample_id), file(pass_files) from COMBINED_SAMPLES_FOR_FASTQC_1

  output:
    set file("${sample_id}_?_fastqc.html") , file("${sample_id}_?_fastqc.zip") optional true into FASTQC_1_OUTPUT

  script:
  """
  fastqc $pass_files
  """
}


/**
 * THIS IS WHERE THE SPLIT HAPPENS FOR hisat2 vs Kallisto vs Salmon
 *
 * Information about "choice" split operator (to be deleted before final
 * GEMmaker release)
 */
HISAT2_CHANNEL = Channel.create()
KALLISTO_CHANNEL = Channel.create()
SALMON_CHANNEL = Channel.create()
COMBINED_SAMPLES_FOR_COUNTING.choice( HISAT2_CHANNEL, KALLISTO_CHANNEL, SALMON_CHANNEL) { params.software.alignment.which_alignment }



/**
 * Performs KALLISTO alignemnt of fastq files
 */
process kallisto {
  publishDir params.output.sample_dir, mode: params.output.publish_mode
  tag { sample_id }
  label "kallisto"

  input:
    set val(sample_id), file(pass_files) from KALLISTO_CHANNEL
    file kallisto_index from file("${params.input.reference_path}/${params.input.reference_prefix}.transcripts.Kallisto.indexed")

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") into KALLISTO_GA
    set val(sample_id), val(1) into CLEAN_MERGED_FASTQ_KALLISTO_SIGNAL

  script:
  """
  if [ -e ${sample_id}_2.fastq ]; then
    kallisto quant \
      -i  ${params.input.reference_prefix}.transcripts.Kallisto.indexed \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      ${sample_id}_1.fastq \
      ${sample_id}_2.fastq
  else
    kallisto quant \
      --single \
      -l 70 \
      -s .0000001 \
      -i ${params.input.reference_prefix}.transcripts.Kallisto.indexed \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      ${sample_id}_1.fastq
  fi
  """
}



/**
 * Generates the final TPM file for Kallisto
 */
process kallisto_tpm {
  publishDir params.output.sample_dir, mode: params.output.publish_mode
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") from KALLISTO_GA

  output:
    file "${sample_id}_vs_${params.input.reference_prefix}.tpm" optional true into KALLISTO_TPM
    val 1  into KALLISTO_SAMPLE_COMPLETE_SIGNAL

  script:
  """
  awk -F"\t" '{if (NR!=1) {print \$1, \$5}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga/abundance.tsv > ${sample_id}_vs_${params.input.reference_prefix}.tpm
  """
}



/**
 * Performs SALMON alignemnt of fastq files
 */
process salmon {
  publishDir params.output.sample_dir, mode: params.output.publish_mode
  tag { sample_id }
  label "salmon"

  input:
    set val(sample_id), file(pass_files) from SALMON_CHANNEL
    file salmon_index from SALMON_INDEXES

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") into SALMON_GA
    set val(sample_id), val(1) into CLEAN_MERGED_FASTQ_SALMON_SIGNAL

  script:
  """
  if [ -e ${sample_id}_2.fastq ]; then
    salmon quant \
      -i . \
      -l A \
      -1 ${sample_id}_1.fastq \
      -2 ${sample_id}_2.fastq \
      -p 8 \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      --minAssignedFrags 1
  else
    salmon quant \
      -i . \
      -l A \
      -r ${sample_id}_1.fastq \
      -p 8 \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      --minAssignedFrags 1
  fi
  """
}



/**
 * Generates the final TPM file for Salmon
 */
process salmon_tpm {
  publishDir params.output.sample_dir, mode: params.output.publish_mode
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") from SALMON_GA

  output:
    file "${sample_id}_vs_${params.input.reference_prefix}.tpm" optional true into SALMON_TPM
    val 1  into SALMON_SAMPLE_COMPLETE_SIGNAL

  script:
  """
  awk -F"\t" '{if (NR!=1) {print \$1, \$4}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga/quant.sf > ${sample_id}_vs_${params.input.reference_prefix}.tpm
  """
}



/**
 * Performs Trimmomatic on all fastq files.
 *
 * This process requires that the ILLUMINACLIP_PATH environment
 * variable be set in the trimmomatic module. This indicates
 * the path where the clipping files are stored.
 *
 * MINLEN is calculated using based on percentage of the mean
 * read length. The percenage is determined by the user in the
 * "nextflow.config" file
 */
process trimmomatic {
  publishDir params.output.sample_dir, mode: params.output.publish_mode, pattern: publish_pattern_trimmomatic
  tag { sample_id }
  label "multithreaded"
  label "trimmomatic"

  input:
    set val(sample_id), file("${sample_id}_?.fastq") from HISAT2_CHANNEL

  output:
    set val(sample_id), file("${sample_id}_*trim.fastq") into TRIMMED_SAMPLES_FOR_FASTQC
    set val(sample_id), file("${sample_id}_*trim.fastq") into TRIMMED_SAMPLES_FOR_HISAT2
    set val(sample_id), file("${sample_id}_*trim.fastq") into TRIMMED_FASTQ_FOR_CLEANING
    set val(sample_id), file("${sample_id}.trim.log") into TRIMMED_SAMPLE_LOG

  script:
  """
  # This script calculates average length of fastq files.
  total=0

  # This if statement checks if the data is single or paired data, and checks length accordingly
  # This script returns 1 number, which can be used for the minlen in trimmomatic
  if [ -e ${sample_id}_1.fastq ] && [ -e ${sample_id}_2.fastq ]; then
    for fastq in ${sample_id}_1.fastq ${sample_id}_2.fastq; do
      a=`awk 'NR%4 == 2 {lengths[length(\$0)]++} END {for (l in lengths) {print l, lengths[l]}}' \$fastq \
      | sort \
      | awk '{ print \$0, \$1*\$2}' \
      | awk '{ SUM += \$3 } { SUM2 += \$2 } END { printf("%.0f", SUM / SUM2 * ${params.software.trimmomatic.MINLEN})} '`
    total=(\$a + \$total)
    done
    total=( \$total / 2 )
    minlen=\$total

  elif [ -e ${sample_id}_1.fastq ]; then
    minlen=`awk 'NR%4 == 2 {lengths[length(\$0)]++} END {for (l in lengths) {print l, lengths[l]}}' ${sample_id}_1.fastq \
      | sort \
      | awk '{ print \$0, \$1*\$2}' \
      | awk '{ SUM += \$3 } { SUM2 += \$2 } END { printf("%.0f", SUM / SUM2 * ${params.software.trimmomatic.MINLEN})} '`
  fi

  if [ -e ${sample_id}_1.fastq ] && [ -e ${sample_id}_2.fastq ]; then
    java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
      PE \
      -threads ${params.execution.threads} \
      ${params.software.trimmomatic.quality} \
      ${sample_id}_1.fastq \
      ${sample_id}_2.fastq \
      ${sample_id}_1p_trim.fastq \
      ${sample_id}_1u_trim.fastq \
      ${sample_id}_2p_trim.fastq \
      ${sample_id}_2u_trim.fastq \
      ILLUMINACLIP:${params.software.trimmomatic.clip_path}:2:40:15 \
      LEADING:${params.software.trimmomatic.LEADING} \
      TRAILING:${params.software.trimmomatic.TRAILING} \
      SLIDINGWINDOW:${params.software.trimmomatic.SLIDINGWINDOW} \
      MINLEN:"\$minlen" > ${sample_id}.trim.log 2>&1
  else
    # For ease of the next steps, rename the reverse file to the forward.
    # since these are non-paired it really shouldn't matter.
    if [ -e ${sample_id}_2.fastq ]; then
      mv ${sample_id}_2.fastq ${sample_id}_1.fastq
    fi
    # Now run trimmomatic
    java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
      SE \
      -threads ${params.execution.threads} \
      ${params.software.trimmomatic.quality} \
      ${sample_id}_1.fastq \
      ${sample_id}_1u_trim.fastq \
      ILLUMINACLIP:${params.software.trimmomatic.clip_path}:2:40:15 \
      LEADING:${params.software.trimmomatic.LEADING} \
      TRAILING:${params.software.trimmomatic.TRAILING} \
      SLIDINGWINDOW:${params.software.trimmomatic.SLIDINGWINDOW} \
      MINLEN:"\$minlen" > ${sample_id}.trim.log 2>&1
  fi
  """
}



/**
 * Performs fastqc on fastq files post trimmomatic
 * Files are stored to an independent folder
 */
process fastqc_2 {
  publishDir params.output.sample_dir, mode: params.output.publish_mode, pattern: "*_fastqc.*"
  tag { sample_id }
  label "fastqc"

  input:
    set val(sample_id), file(pass_files) from TRIMMED_SAMPLES_FOR_FASTQC

  output:
    set file("${sample_id}_??_trim_fastqc.html"), file("${sample_id}_??_trim_fastqc.zip") optional true into FASTQC_2_OUTPUT

  script:
  """
  fastqc $pass_files
  """
}



/**
 * Performs hisat2 alignment of fastq files to a genome reference
 *
 * depends: trimmomatic
 */
process hisat2 {
  publishDir params.output.sample_dir, mode: params.output.publish_mode, pattern: "*.log"
  tag { sample_id }
  label "multithreaded"
  label "hisat2"

  input:
    set val(sample_id), file(input_files) from TRIMMED_SAMPLES_FOR_HISAT2
    file indexes from HISAT2_INDEXES
    file gtf_file from GTF_FILE

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam") into INDEXED_SAMPLES
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam.log") into INDEXED_SAMPLES_LOG
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam") into SAM_FOR_CLEANING
    set val(sample_id), val(1) into CLEAN_TRIMMED_FASTQ_SIGNAL
    set val(sample_id), val(1) into CLEAN_MERGED_FASTQ_HISAT_SIGNAL

  script:
  """
  if [ -e ${sample_id}_2p_trim.fastq ]; then
    hisat2 \
      -x ${params.input.reference_prefix} \
      --no-spliced-alignment \
      -q \
      -1 ${sample_id}_1p_trim.fastq \
      -2 ${sample_id}_2p_trim.fastq \
      -U ${sample_id}_1u_trim.fastq,${sample_id}_2u_trim.fastq \
      -S ${sample_id}_vs_${params.input.reference_prefix}.sam \
      -t \
      -p ${params.execution.threads} \
      --un ${sample_id}_un.fastq \
      --dta-cufflinks \
      --new-summary \
      --summary-file ${sample_id}_vs_${params.input.reference_prefix}.sam.log
  else
    hisat2 \
      -x ${params.input.reference_prefix} \
      --no-spliced-alignment \
      -q \
      -U ${sample_id}_1u_trim.fastq \
      -S ${sample_id}_vs_${params.input.reference_prefix}.sam \
      -t \
      -p ${params.execution.threads} \
      --un ${sample_id}_un.fastq \
      --dta-cufflinks \
      --new-summary \
      --summary-file ${sample_id}_vs_${params.input.reference_prefix}.sam.log
  fi
  """
}



/**
 * Sorts the SAM alignment file and coverts it to binary BAM
 *
 * depends: hisat2
 */
process samtools_sort {
  publishDir params.output.sample_dir, mode: params.output.publish_mode, pattern: publish_pattern_samtools_sort
  tag { sample_id }
  label "samtools"

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam") from INDEXED_SAMPLES

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") into SORTED_FOR_INDEX
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") into BAM_FOR_CLEANING
    set val(sample_id), val(1) into CLEAN_SAM_SIGNAL

  script:
    """
    samtools sort -o ${sample_id}_vs_${params.input.reference_prefix}.bam -O bam ${sample_id}_vs_${params.input.reference_prefix}.sam -T temp
    """
}



/**
 * Indexes the BAM alignment file
 *
 * depends: samtools_index
 */
process samtools_index {
  publishDir params.output.sample_dir, mode: params.output.publish_mode, pattern: publish_pattern_samtools_index
  tag { sample_id }
  label "samtools"

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") from SORTED_FOR_INDEX

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") into BAM_INDEXED_FOR_STRINGTIE
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam.bai") into BAI_INDEXED_FILE
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam.log") into BAM_INDEXED_LOG

  script:
    """
    samtools index ${sample_id}_vs_${params.input.reference_prefix}.bam
    samtools stats ${sample_id}_vs_${params.input.reference_prefix}.bam > ${sample_id}_vs_${params.input.reference_prefix}.bam.log
    """
}



/**
 * Generates expression-level transcript abundance
 *
 * depends: samtools_index
 */
process stringtie {
  tag { sample_id }

  label "multithreaded"
  label "stringtie"

  input:
    // We don't really need the .bam file, but we want to ensure
    // this process runs after the samtools_index step so we
    // require it as an input file.
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") from BAM_INDEXED_FOR_STRINGTIE
    file gtf_file from GTF_FILE

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") into STRINGTIE_GTF
    set val(sample_id), val(1) into CLEAN_BAM_SIGNAL

  script:
    """
    stringtie \
    -v \
    -p ${params.execution.threads} \
    -e \
    -o ${sample_id}_vs_${params.input.reference_prefix}.gtf \
    -G ${gtf_file} \
    -A ${sample_id}_vs_${params.input.reference_prefix}.ga \
    -l ${sample_id} ${sample_id}_vs_${params.input.reference_prefix}.bam
    """
}



/**
 * Generates the final FPKM file
 */
process fpkm_or_tpm {
  publishDir params.output.sample_dir, mode: params.output.publish_mode
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") from STRINGTIE_GTF

  output:
    file "${sample_id}_vs_${params.input.reference_prefix}.fpkm" optional true into FPKMS
    file "${sample_id}_vs_${params.input.reference_prefix}.tpm" optional true into TPM
    val 1  into HISAT2_SAMPLE_COMPLETE_SIGNAL

  script:
  if ( params.output.publish_fpkm == true && params.output.publish_tpm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$8}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.fpkm
    awk -F"\t" '{if (NR!=1) {print \$1, \$9}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.tpm
    """
  else if ( params.output.publish_fpkm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$8}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.fpkm
    """
  else if ( params.output.publish_tpm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$9}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.tpm
    """
  else
    error "Please choose at least one output and resume GEMmaker"
}



/**
 * PROCESSES FOR CLEANING LARGE FILES
 *
 * Nextflow doesn't allow files to be removed from the
 * work directories that are used in Channels.  If it
 * detects a different timestamp or change in file
 * size than what was cached it will rerun the process.
 * To trick Nextflow we will truncate the file to a
 * sparce file of size zero but masquerading as its
 * original size, we will also reset the original modify
 * and access times.
 */


/**
 * Merge the fastq_dump files with SRR_combine signal 
 * so that we can remove these files.
 */

RFCLEAN = DOWNLOADED_FASTQ_FOR_CLEANING.mix(CLEAN_DOWNLOADED_FASTQ_SIGNAL)
RFCLEAN.groupTuple(size: 2).set { DOWNLOADED_FASTQ_CLEANUP_READY }

/**
 * Cleans downloaded fastq files
 */
process clean_downloaded_fastq {
  tag { sample_id }

  input:
    set val(sample_id), val(files_list) from DOWNLOADED_FASTQ_CLEANUP_READY

  when: 
    params.output.publish_downloaded_fastq == false

  script:
    template "clean_work_files.sh"
}



/**
 * Merge the merged fastq files with the signals from hista2, 
 * kallisto and salmon to clean up merged fastq files. This
 * is only needed for remote files that were downloaded
 * and then merged into a single sample in the SRR_combine
 * process.
 */
MFCLEAN = MERGED_FASTQ_FOR_CLEANING.mix(CLEAN_MERGED_FASTQ_HISAT_SIGNAL, CLEAN_MERGED_FASTQ_KALLISTO_SIGNAL, CLEAN_MERGED_FASTQ_SALMON_SIGNAL)
MFCLEAN.groupTuple(size: 2).set { MERGED_FASTQ_CLEANUP_READY }

/**
 * Cleans merged fastq files
 */
process clean_merged_fastq {
  tag { sample_id }

  input:
    set val(sample_id), val(files_list) from MERGED_FASTQ_CLEANUP_READY

  when:
    params.output.publish_downloaded_fastq == false

  script:
    template "clean_work_files.sh"
}



/**
 * Merge the Trimmomatic samples with Hisat's signal that it is
 * done so that we can remove these files.
 */
TRHIMIX = TRIMMED_FASTQ_FOR_CLEANING.mix(CLEAN_TRIMMED_FASTQ_SIGNAL)
TRHIMIX.groupTuple(size: 2).set { TRIMMED_FASTQ_CLEANUP_READY }

/**
 * Cleans trimmed fastq files
 */
process clean_trimmed_fastq {
  tag { sample_id }

  input:
    set val(sample_id), val(files_list) from TRIMMED_FASTQ_CLEANUP_READY

  when: 
    params.output.publish_trimmed_fastq == false

  script:
    template "clean_work_files.sh"
}



/**
 * Merge the HISAT sam file with samtools_sort signal that it is
 * done so that we can remove these files.
 */
HISSMIX = SAM_FOR_CLEANING.mix(CLEAN_SAM_SIGNAL)
HISSMIX.groupTuple(size: 2).set { SAM_CLEANUP_READY }

/**
 * Clean up SAM files
 */
process clean_sam {
  tag { sample_id }

  input:
    set val(sample_id), val(files_list) from SAM_CLEANUP_READY

  script:
    template "clean_work_files.sh"
}



/**
 * Merge the samtools_sort bam file with stringtie signal that it is
 * done so that we can remove these files.
 */
SSSTMIX = BAM_FOR_CLEANING.mix(CLEAN_BAM_SIGNAL)
SSSTMIX.groupTuple(size: 2).set { BAM_CLEANUP_READY }

/**
 * Clean up BAM files
 */
process clean_bam {
  tag { sample_id }

  input:
    set val(sample_id), val(files_list) from BAM_CLEANUP_READY

  when: 
    params.output.publish_bam == false

  script:
    template "clean_work_files.sh"
}


