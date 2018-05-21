#!/usr/bin/env nextflow
/*
vim: syntax=groovy
-*- mode: groovy;-*-
========================================================================================
                         B U L K - R N A S E Q    P I P E L I N E
========================================================================================
 Cellular Genetics bulk-RNA-Seq analysis pipeline, Wellcome Sanger Institute
 #### Homepage / Documentation
 https://github.com/cellgeni/RNAseq
 #### Authors
 Vladimir Kiselev @wikiselev <vk6@sanger.ac.uk>
 Original development by SciLifeLabs
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info"""
    =========================================
     Bulk-RNA-Seq pipeline v${version}
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run cellgeni/RNAseq --reads '*_R{1,2}.fastq.gz' --genome GRCh37 -profile farm3

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      --genome                      Name of iGenomes reference
      -profile                      Hardware config to use. farm3 / farm4 / openstack / docker / aws

    Strandedness:
      --forward_stranded            The library is forward stranded
      --reverse_stranded            The library is reverse stranded
      --unstranded                  The default behaviour

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --star_index                  Path to STAR index
      --star_overhang               sjdbOverhang parameter for building a STAR index (has to be (read_length - 1))
      --fasta                       Path to Fasta reference
      --gtf                         Path to GTF file
      --bed12                       Path to bed12 file
      --downloadFasta               If no STAR / Fasta reference is supplied, a URL can be supplied to download a Fasta file at the start of the pipeline.
      --downloadGTF                 If no GTF reference is supplied, a URL can be supplied to download a Fasta file at the start of the pipeline.
      --saveReference               Save the generated reference files the the Results directory.
      --saveAlignedIntermediates    Save the BAM files from the Aligment step  - not done by default

    Trimming options
      --clip_r1 [int]               Instructs Trim Galore to remove bp from the 5' end of read 1 (or single-end reads)
      --clip_r2 [int]               Instructs Trim Galore to remove bp from the 5' end of read 2 (paired-end reads only)
      --three_prime_clip_r1 [int]   Instructs Trim Galore to remove bp from the 3' end of read 1 AFTER adapter/quality trimming has been performed
      --three_prime_clip_r2 [int]   Instructs Trim Galore to re move bp from the 3' end of read 2 AFTER adapter/quality trimming has been performed

    Presets:
      --pico                        Sets trimming and standedness settings for the SMARTer Stranded Total RNA-Seq Kit - Pico Input kit. Equivalent to: --forward_stranded --clip_r1 3 --three_prime_clip_r2 3

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --sampleLevel                 Used to turn of the edgeR MDS and heatmap. Set automatically when running on fewer than 3 samples
      --clusterOptions              Extra SLURM options, used in conjunction with Uppmax.config
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Pipeline version
version = '1.5'

// Show help message
params.help = false
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.irods_username = 'vk6'
params.irods_keytab = '~/irods.keytab'
params.name = false
params.project = false
params.genome = 'GRCh38'
params.forward_stranded = false
params.reverse_stranded = false
params.unstranded = false
params.star_index = params.genome ? params.genomes[ params.genome ].star ?: false : false
params.star_overhang = '74'
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
params.bed12 = params.genome ? params.genomes[ params.genome ].bed12 ?: false : false
params.hisat2_index = params.genome ? params.genomes[ params.genome ].hisat2 ?: false : false
params.multiqc_config = "$baseDir/conf/multiqc_config.yaml"
params.splicesites = false
params.download_hisat2index = false
params.download_fasta = false
params.download_gtf = false
params.hisatBuildMemory = 200 // Required amount of memory in GB to build HISAT2 index with splice sites
params.saveReference = false
params.saveTrimmed = false
params.saveAlignedIntermediates = false
params.reads = 'cram/*.cram'
params.outdir = './results'
params.email = false
params.plaintext_email = false
params.mdsplot_header = "$baseDir/assets/mdsplot_header.txt"
params.heatmap_header = "$baseDir/assets/heatmap_header.txt"
params.biotypes_header= "$baseDir/assets/biotypes_header.txt"

mdsplot_header = file(params.mdsplot_header)
heatmap_header = file(params.heatmap_header)
biotypes_header = file(params.biotypes_header)
multiqc_config = file(params.multiqc_config)
output_docs = file("$baseDir/docs/output.md")
params.sampleLevel = false

// Custom trimming options
params.clip_r1 = 0
params.clip_r2 = 0
params.three_prime_clip_r1 = 0
params.three_prime_clip_r2 = 0

// Define regular variables so that they can be overwritten
clip_r1 = params.clip_r1
clip_r2 = params.clip_r2
three_prime_clip_r1 = params.three_prime_clip_r1
three_prime_clip_r2 = params.three_prime_clip_r2
forward_stranded = params.forward_stranded
reverse_stranded = params.reverse_stranded
unstranded = params.unstranded

// Preset trimming options
params.pico = false
if (params.pico){
  clip_r1 = 3
  clip_r2 = 0
  three_prime_clip_r1 = 0
  three_prime_clip_r2 = 3
  forward_stranded = true
  reverse_stranded = false
  unstranded = false
}

// Choose aligner
params.aligner = 'star'
if (params.aligner != 'star' && params.aligner != 'hisat2'){
    exit 1, "Invalid aligner option: ${params.aligner}. Valid options: 'star', 'hisat2'"
}

// Validate inputs
if( params.star_index && params.aligner == 'star' ){
    star_index = Channel
        .fromPath(params.star_index)
        .ifEmpty { exit 1, "STAR index not found: ${params.star_index}" }
}
else if ( params.hisat2_index && params.aligner == 'hisat2' ){
    hs2_indices = Channel
        .fromPath("${params.hisat2_index}*")
        .ifEmpty { exit 1, "HISAT2 index not found: ${params.hisat2_index}" }
}
else if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}
else if ( ( params.aligner == 'hisat2' && !params.download_hisat2index ) && !params.download_fasta ){
    exit 1, "No reference genome specified!"
}

if( params.gtf ){
    Channel
        .fromPath(params.gtf)
        .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
        .into { gtf_makeSTARindex; gtf_makeHisatSplicesites; gtf_makeHISATindex; gtf_makeBED12;
              gtf_star; gtf_dupradar; gtf_featureCounts; gtf_stringtieFPKM }
}
else if ( !params.download_gtf ){
    exit 1, "No GTF annotation specified!"
}
if( params.bed12 ){
    bed12 = Channel
        .fromPath(params.bed12)
        .ifEmpty { exit 1, "BED12 annotation file not found: ${params.bed12}" }
        .into {bed_rseqc; bed_genebody_coverage}
}
if( params.aligner == 'hisat2' && params.splicesites ){
    Channel
        .fromPath(params.bed12)
        .ifEmpty { exit 1, "HISAT2 splice sites file not found: $alignment_splicesites" }
        .into { indexing_splicesites; alignment_splicesites }
}
if( workflow.profile == 'uppmax' || workflow.profile == 'uppmax-modules' || workflow.profile == 'uppmax-devel' ){
    if ( !params.project ) exit 1, "No UPPMAX project ID found! Use --project"
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


// Header log info
log.info "========================================="
log.info "         RNASeq pipeline v${version}"
log.info "========================================="
def summary = [:]
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Data Type']    = 'Paired-End'
summary['Genome']       = params.genome
if( params.pico ) summary['Library Prep'] = "SMARTer Stranded Total RNA-Seq Kit - Pico Input"
summary['Strandedness'] = ( unstranded ? 'None' : forward_stranded ? 'Forward' : reverse_stranded ? 'Reverse' : 'None' )
summary['Trim R1'] = clip_r1
summary['Trim R2'] = clip_r2
summary["Trim 3' R1"] = three_prime_clip_r1
summary["Trim 3' R2"] = three_prime_clip_r2
if(params.aligner == 'star'){
    summary['Aligner'] = "STAR"
    if(params.star_index)          summary['STAR Index']   = params.star_index
    else if(params.fasta)          summary['Fasta Ref']    = params.fasta
    else if(params.download_fasta) summary['Fasta URL']    = params.download_fasta
} else if(params.aligner == 'hisat2') {
    summary['Aligner'] = "HISAT2"
    if(params.hisat2_index)        summary['HISAT2 Index'] = params.hisat2_index
    else if(params.download_hisat2index) summary['HISAT2 Index'] = params.download_hisat2index
    else if(params.fasta)          summary['Fasta Ref']    = params.fasta
    else if(params.download_fasta) summary['Fasta URL']    = params.download_fasta
    if(params.splicesites)         summary['Splice Sites'] = params.splicesites
}
if(params.gtf)                 summary['GTF Annotation']  = params.gtf
else if(params.download_gtf)   summary['GTF URL']         = params.download_gtf
if(params.bed12)               summary['BED Annotation']  = params.bed12
summary['Save Reference'] = params.saveReference ? 'Yes' : 'No'
summary['Save Trimmed']   = params.saveTrimmed ? 'Yes' : 'No'
summary['Save Intermeds'] = params.saveAlignedIntermediates ? 'Yes' : 'No'
summary['Max Memory']     = params.max_memory
summary['Max CPUs']       = params.max_cpus
summary['Max Time']       = params.max_time
summary['Output dir']     = params.outdir
summary['Working dir']    = workflow.workDir
summary['Container']      = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
if(params.project) summary['UPPMAX Project'] = params.project
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
nf_required_version = '0.25.0'
try {
    if( ! nextflow.version.matches(">= $nf_required_version") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}

// Show a big error message if we're running on the base config and an uppmax cluster
if( workflow.profile == 'standard'){
    if ( "hostname".execute().text.contains('.uppmax.uu.se') ) {
        log.error "====================================================\n" +
                  "  WARNING! You are running with the default 'standard'\n" +
                  "  pipeline config profile, which runs on the head node\n" +
                  "  and assumes all software is on the PATH.\n" +
                  "  ALL JOBS ARE RUNNING LOCALLY and stuff will probably break.\n" +
                  "  Please use `-profile uppmax` to run on UPPMAX clusters.\n" +
                  "============================================================"
    }
}


/*
 * PREPROCESSING - Download Fasta
 */
if(((params.aligner == 'star' && !params.star_index) || (params.aligner == 'hisat2' && !params.hisat2_index)) && !params.fasta && params.download_fasta){
    process downloadFASTA {
        tag "${params.download_fasta}"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        output:
        file "*.{fa,fasta}" into fasta

        script:
        """
        curl -O -L ${params.download_fasta}
        if [ -f *.tar.gz ]; then
            tar xzf *.tar.gz
        elif [ -f *.gz ]; then
            gzip -d *.gz
        fi
        """
    }
}
/*
 * PREPROCESSING - Download GTF
 */
if(!params.gtf && params.download_gtf){
    process downloadGTF {
        tag "${params.download_gtf}"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        output:
        file "*.gtf" into gtf_makeSTARindex, gtf_makeHisatSplicesites, gtf_makeHISATindex, gtf_makeBED12, gtf_star, gtf_dupradar, gtf_featureCounts, gtf_stringtieFPKM

        script:
        """
        curl -O -L ${params.download_gtf}
        if [ -f *.tar.gz ]; then
            tar xzf *.tar.gz
        elif [ -f *.gz ]; then
            gzip -d *.gz
        fi
        """
    }
}
/*
 * PREPROCESSING - Download HISAT2 Index
 */
 if( params.aligner == 'hisat2' && params.download_hisat2index && !params.hisat2_index){
    process downloadHS2Index {
        tag "${params.download_hisat2index}"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        output:
        file "*/*.ht2" into hs2_indices

        script:
        """
        curl -O -L ${params.download_hisat2index}
        if [ -f *.tar.gz ]; then
            tar xzf *.tar.gz
        elif [ -f *.gz ]; then
            gzip -d *.gz
        fi
        """
    }
}
/*
 * PREPROCESSING - Build STAR index
 */
if(params.aligner == 'star' && !params.star_index && fasta){
    process makeSTARindex {
        tag fasta
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        beforeScript "set +u; source activate rnaseq${version}"
        afterScript "set +u; source deactivate"

        input:
        file fasta from fasta
        file gtf from gtf_makeSTARindex

        output:
        file "star" into star_index

        script:
        """
        mkdir star
        STAR \\
            --runMode genomeGenerate \\
            --runThreadN ${task.cpus} \\
            --sjdbGTFfile $gtf \\
            --sjdbOverhang ${params.star_overhang} \\
            --genomeDir star/ \\
            --genomeFastaFiles $fasta
        """
    }
}
/*
 * PREPROCESSING - Build HISAT2 splice sites file
 */
if(params.aligner == 'hisat2' && !params.splicesites){
    process makeHisatSplicesites {
        tag "$gtf"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file gtf from gtf_makeHisatSplicesites

        output:
        file "${gtf.baseName}.hisat2_splice_sites.txt" into indexing_splicesites, alignment_splicesites

        script:
        """
        hisat2_extract_splice_sites.py $gtf > ${gtf.baseName}.hisat2_splice_sites.txt
        """
    }
}
/*
 * PREPROCESSING - Build HISAT2 index
 */
if(params.aligner == 'hisat2' && !params.hisat2_index && !params.download_hisat2index && fasta){
    process makeHISATindex {
        tag "$fasta"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta from fasta
        file indexing_splicesites from indexing_splicesites
        file gtf from gtf_makeHISATindex

        output:
        file "${fasta.baseName}.*.ht2" into hs2_indices

        script:
        if( task.memory == null ){
            log.info "[HISAT2 index build] Available memory not known - defaulting to 0. Specify process memory requirements to change this."
            avail_mem = 0
        } else {
            log.info "[HISAT2 index build] Available memory: ${task.memory}"
            avail_mem = task.memory.toGiga()
        }
        if( avail_mem > params.hisatBuildMemory ){
            log.info "[HISAT2 index build] Over ${params.hisatBuildMemory} GB available, so using splice sites and exons in HISAT2 index"
            extract_exons = "hisat2_extract_exons.py $gtf > ${gtf.baseName}.hisat2_exons.txt"
            ss = "--ss $indexing_splicesites"
            exon = "--exon ${gtf.baseName}.hisat2_exons.txt"
        } else {
            log.info "[HISAT2 index build] Less than ${params.hisatBuildMemory} GB available, so NOT using splice sites and exons in HISAT2 index."
            log.info "[HISAT2 index build] Use --hisatBuildMemory [small number] to skip this check."
            extract_exons = ''
            ss = ''
            exon = ''
        }
        """
        $extract_exons
        hisat2-build -p ${task.cpus} $ss $exon $fasta ${fasta.baseName}.hisat2_index
        """
    }
}
/*
 * PREPROCESSING - Build BED12 file
 */
if(!params.bed12){
    process makeBED12 {
        tag "$gtf"
        publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file gtf from gtf_makeBED12

        output:
        file "${gtf.baseName}.bed" into bed_rseqc, bed_genebody_coverage

        script: // This script is bundled with the pipeline, in RNAseq/bin/
        """
        gtf2bed $gtf > ${gtf.baseName}.bed
        """
    }
}

/*
 * Create a channel for input sample ids
 */
sample_list = Channel.fromPath('samples.txt')

process irods {
    tag "${sample}"
    
    //beforeScript "kinit ${params.irods_username} -k -t ${params.irods_keytab}"
    input: 
        val sample from sample_list.flatMap{ it.readLines() }
    output: 
        set val(sample), file('*.cram') optional true into cram_files
    script:
    """
    irods.sh ${sample}
    """
}

process merge_sample_crams {
    tag "${sample}"

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input: 
        set val(sample), file(crams) from cram_files
    output: 
        file "${sample}.cram" into sample_cram_file
    script:
    """
    samtools merge -f ${sample}.cram ${crams}
    """
}

/*
 * STEP 1 - cram to fastq conversion
 */

process cram2fastq {
    tag "${cram.baseName}"
    
    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file cram from sample_cram_file

    output:
    set val(cram), file("*.fastq") optional true into fastq_fastqc
    set val(cram), file("*.fastq") optional true into fastq_trim_galore

    script:
    // samtools consumes more than what's available
    def avail_mem = task.memory == null ? '' : "${ ( task.memory.toBytes() - 2000000000 ) / task.cpus}"
    """
    # check that the size of the cram file is >3Mb
    minimumsize=3000000
    actualsize=\$(wc -c <"${cram}")
    if [ \$actualsize -ge \$minimumsize ]; then
        samtools sort \\
            -n \\
            -@ ${task.cpus} \\
            -m ${avail_mem} \\
            ${cram} | \\
            samtools fastq \\
                -N \\
                -@ ${task.cpus} \\
                -1 ${cram.baseName}_1.fastq \\
                -2 ${cram.baseName}_2.fastq \\
                -
    fi
    """
}

/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "${cram.baseName}"
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    beforeScript "set +u; source /nfs/cellgeni/.cellgenirc"
    // beforeScript "set +u; source activate rnaseq${version}"
    // afterScript "set +u; source deactivate"

    input:
    set val(cram), file(reads) from fastq_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results
    file '.command.out' into fastqc_stdout

    script:
    """
    fastqc -q $reads
    fastqc --version
    """
}

/*
 * STEP 2 - Trim Galore!
 */
process trim_galore {
    tag "${cram.baseName}"
    publishDir "${params.outdir}/trim_galore", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("_fastqc") > 0) "FastQC/$filename"
            else if (filename.indexOf("trimming_report.txt") > 0) "logs/$filename"
            else params.saveTrimmed ? filename : null
        }

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    set val(cram), file(reads) from fastq_trim_galore

    output:
    file "*fq.gz" into trimmed_reads
    file "*trimming_report.txt" into trimgalore_results, trimgalore_logs
    file "*_fastqc.{zip,html}" into trimgalore_fastqc_reports


    script:
    c_r1 = clip_r1 > 0 ? "--clip_r1 ${clip_r1}" : ''
    c_r2 = clip_r2 > 0 ? "--clip_r2 ${clip_r2}" : ''
    tpc_r1 = three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 ${three_prime_clip_r1}" : ''
    tpc_r2 = three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 ${three_prime_clip_r2}" : ''
    """
    trim_galore --paired --fastqc --gzip $c_r1 $c_r2 $tpc_r1 $tpc_r2 $reads
    """
}


/*
 * STEP 3 - align with STAR
 */
// Function that checks the alignment rate of the STAR output
// and returns true if the alignment passed and otherwise false
skipped_poor_alignment = []
def check_log(logs) {
    def percent_aligned = 0;
    logs.eachLine { line ->
        if ((matcher = line =~ /Uniquely mapped reads %\s*\|\s*([\d\.]+)%/)) {
            percent_aligned = matcher[0][1]
        }
    }
    logname = logs.getBaseName() - 'Log.final'
    if(percent_aligned.toFloat() <= '5'.toFloat() ){
        log.info "#################### VERY POOR ALIGNMENT RATE! IGNORING FOR FURTHER DOWNSTREAM ANALYSIS! ($logname)    >> ${percent_aligned}% <<"
        skipped_poor_alignment << logname
        return false
    } else {
        log.info "          Passed alignment > star ($logname)   >> ${percent_aligned}% <<"
        return true
    }
}
if(params.aligner == 'star'){
    hisat_stdout = Channel.from(false)
    process star {
        tag "$prefix"
        publishDir "${params.outdir}/STAR", mode: 'copy',
            saveAs: {filename ->
                if (filename.indexOf(".bam") == -1) "logs/$filename"
                else params.saveAlignedIntermediates ? filename : null
            }

        beforeScript "set +u; source activate rnaseq${version}"
        afterScript "set +u; source deactivate"

        input:
        file reads from trimmed_reads
        file index from star_index.collect()
        file gtf from gtf_star.collect()

        output:
        set file("*Log.final.out"), file ('*.bam') into star_aligned
        file "*.out" into alignment_logs
        file "*SJ.out.tab"
        file "*Log.out" into star_log

        script:
        prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
        """
        STAR --genomeDir $index \\
            --sjdbGTFfile $gtf \\
            --readFilesIn $reads  \\
            --runThreadN ${task.cpus} \\
            --twopassMode Basic \\
            --outWigType bedGraph \\
            --outSAMtype BAM SortedByCoordinate \\
            --readFilesCommand gunzip -c \\
            --runDirPerm All_RWX \\
            --outFileNamePrefix $prefix
        """
    }
    // Filter removes all 'aligned' channels that fail the check
    star_aligned
        .filter { logs, bams -> check_log(logs) }
        .flatMap {  logs, bams -> bams }
    .into { bam_count; bam_rseqc; bam_preseq; bam_markduplicates; bam_featurecounts; bam_stringtieFPKM; bam_geneBodyCoverage }
}


/*
 * STEP 3 - align with HISAT2
 */
if(params.aligner == 'hisat2'){
    star_log = Channel.from(false)
    process hisat2Align {
        tag "$prefix"
        publishDir "${params.outdir}/HISAT2", mode: 'copy',
            saveAs: {filename ->
                if (filename.indexOf(".hisat2_summary.txt") > 0) "logs/$filename"
                else params.saveAlignedIntermediates ? filename : null
            }

        beforeScript "set +u; source activate rnaseq${version}"
        afterScript "set +u; source deactivate"

        input:
        file reads from trimmed_reads
        file hs2_indices from hs2_indices.collect()
        file alignment_splicesites from alignment_splicesites.collect()

        output:
        file "${prefix}.bam" into hisat2_bam
        file "${prefix}.hisat2_summary.txt" into alignment_logs
        file '.command.log' into hisat_stdout

        script:
        index_base = hs2_indices[0].toString() - ~/.\d.ht2/
        prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
        def rnastrandness = ''
        if (forward_stranded && !unstranded){
            rnastrandness = '--rna-strandness FR'
        } else if (reverse_stranded && !unstranded){
            rnastrandness = '--rna-strandness RF'
        }
        """
        hisat2 -x $index_base \\
                -1 ${reads[0]} \\
                -2 ${reads[1]} \\
                $rnastrandness \\
                --known-splicesite-infile $alignment_splicesites \\
                --no-mixed \\
                --no-discordant \\
                -p ${task.cpus} \\
                --met-stderr \\
                --new-summary \\
                --summary-file ${prefix}.hisat2_summary.txt \\
                | samtools view -bS -F 4 -F 8 -F 256 - > ${prefix}.bam
        hisat2 --version
        """
    }

    process hisat2_sortOutput {
        tag "${hisat2_bam.baseName}"
        publishDir "${params.outdir}/HISAT2", mode: 'copy',
            saveAs: {filename -> params.saveAlignedIntermediates ? "aligned_sorted/$filename" : null }

        beforeScript "set +u; source activate rnaseq${version}"
        afterScript "set +u; source deactivate"

        input:
        file hisat2_bam

        output:
        file "${hisat2_bam.baseName}.sorted.bam" into bam_count, bam_rseqc, bam_preseq, bam_markduplicates, bam_featurecounts, bam_stringtieFPKM, bam_geneBodyCoverage

        script:
        def avail_mem = task.memory == null ? '' : "-m ${task.memory.toBytes() / task.cpus}"
        """
        samtools sort \\
            $hisat2_bam \\
            -@ ${task.cpus} $avail_mem \\
            -o ${hisat2_bam.baseName}.sorted.bam
        """
    }
}
/*
 * STEP 4 - RSeQC analysis
 */
process rseqc {
    tag "${bam_rseqc.baseName - '.sorted'}"
    publishDir "${params.outdir}/rseqc" , mode: 'copy',
        saveAs: {filename ->
                 if (filename.indexOf("bam_stat.txt") > 0)                      "bam_stat/$filename"
            else if (filename.indexOf("infer_experiment.txt") > 0)              "infer_experiment/$filename"
            else if (filename.indexOf("read_distribution.txt") > 0)             "read_distribution/$filename"
            else if (filename.indexOf("read_duplication.DupRate_plot.pdf") > 0) "read_duplication/$filename"
            else if (filename.indexOf("read_duplication.DupRate_plot.r") > 0)   "read_duplication/rscripts/$filename"
            else if (filename.indexOf("read_duplication.pos.DupRate.xls") > 0)  "read_duplication/dup_pos/$filename"
            else if (filename.indexOf("read_duplication.seq.DupRate.xls") > 0)  "read_duplication/dup_seq/$filename"
            else if (filename.indexOf("RPKM_saturation.eRPKM.xls") > 0)         "RPKM_saturation/rpkm/$filename"
            else if (filename.indexOf("RPKM_saturation.rawCount.xls") > 0)      "RPKM_saturation/counts/$filename"
            else if (filename.indexOf("RPKM_saturation.saturation.pdf") > 0)    "RPKM_saturation/$filename"
            else if (filename.indexOf("RPKM_saturation.saturation.r") > 0)      "RPKM_saturation/rscripts/$filename"
            else if (filename.indexOf("inner_distance.txt") > 0)                "inner_distance/$filename"
            else if (filename.indexOf("inner_distance_freq.txt") > 0)           "inner_distance/data/$filename"
            else if (filename.indexOf("inner_distance_plot.r") > 0)             "inner_distance/rscripts/$filename"
            else if (filename.indexOf("inner_distance_plot.pdf") > 0)           "inner_distance/plots/$filename"
            else if (filename.indexOf("junction_plot.r") > 0)                   "junction_annotation/rscripts/$filename"
            else if (filename.indexOf("junction.xls") > 0)                      "junction_annotation/data/$filename"
            else if (filename.indexOf("splice_events.pdf") > 0)                 "junction_annotation/events/$filename"
            else if (filename.indexOf("splice_junction.pdf") > 0)               "junction_annotation/junctions/$filename"
            else if (filename.indexOf("junctionSaturation_plot.pdf") > 0)       "junction_saturation/$filename"
            else if (filename.indexOf("junctionSaturation_plot.r") > 0)         "junction_saturation/rscripts/$filename"
            else if (filename.indexOf("log.txt") > -1) false
            else "$filename"
        }

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file bam_rseqc
    file bed12 from bed_rseqc.collect()

    output:
    file "*.{txt,pdf,r,xls}" into rseqc_results

    script:
    def strandRule = ''
    if (forward_stranded && !unstranded){
        strandRule = '-d 1++,1--,2+-,2-+'
    } else if (reverse_stranded && !unstranded){
        strandRule = '-d 1+-,1-+,2++,2--'
    }
    """
    samtools index $bam_rseqc
    infer_experiment.py -i $bam_rseqc -r $bed12 > ${bam_rseqc.baseName}.infer_experiment.txt
    junction_annotation.py -i $bam_rseqc -o ${bam_rseqc.baseName}.rseqc -r $bed12
    bam_stat.py -i $bam_rseqc 2> ${bam_rseqc.baseName}.bam_stat.txt
    junction_saturation.py -i $bam_rseqc -o ${bam_rseqc.baseName}.rseqc -r $bed12 2> ${bam_rseqc.baseName}.junction_annotation_log.txt
    inner_distance.py -i $bam_rseqc -o ${bam_rseqc.baseName}.rseqc -r $bed12
    read_distribution.py -i $bam_rseqc -r $bed12 > ${bam_rseqc.baseName}.read_distribution.txt
    read_duplication.py -i $bam_rseqc -o ${bam_rseqc.baseName}.read_duplication
    echo "Filename $bam_rseqc RseQC version: "\$(read_duplication.py --version)
    """
}

/*
 * Step 4.1 Rseqc genebody_coverage
 */
process genebody_coverage {
    tag "${bam_geneBodyCoverage.baseName - '.sorted'}"
       publishDir "${params.outdir}/rseqc" , mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("geneBodyCoverage.curves.pdf") > 0)       "geneBodyCoverage/$filename"
            else if (filename.indexOf("geneBodyCoverage.r") > 0)                "geneBodyCoverage/rscripts/$filename"
            else if (filename.indexOf("geneBodyCoverage.txt") > 0)              "geneBodyCoverage/data/$filename"
            else "$filename"
        }

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file bam_geneBodyCoverage
    file bed12 from bed_genebody_coverage.collect()

    output:
    file "*.{txt,pdf,r,xls}" into genebody_coverage_results

    script:
    """
    cat <(samtools view -H ${bam_geneBodyCoverage}) \\
        <(samtools view ${bam_geneBodyCoverage} | shuf -n 1000000) \\
        | samtools sort - -o ${bam_geneBodyCoverage.baseName}_subsamp_sorted.bam
    samtools index ${bam_geneBodyCoverage.baseName}_subsamp_sorted.bam
    geneBody_coverage.py -i ${bam_geneBodyCoverage.baseName}_subsamp_sorted.bam -o ${bam_geneBodyCoverage.baseName}.rseqc -r $bed12
    """
}

/*
 * STEP 5 - preseq analysis
 */
process preseq {
    tag "${bam_preseq.baseName - '.sorted'}"
    publishDir "${params.outdir}/preseq", mode: 'copy'

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file bam_preseq

    output:
    file "${bam_preseq.baseName}.ccurve.txt" into preseq_results
    file '.command.log' into preseq_stdout

    script:
    """
    preseq lc_extrap -v -B $bam_preseq -o ${bam_preseq.baseName}.ccurve.txt
    echo "File name: $bam_preseq  preseq version: "\$(preseq)
    """
}


/*
 * STEP 6 Mark duplicates
 */
process markDuplicates {
    tag "${bam_markduplicates.baseName - '.sorted'}"
    publishDir "${params.outdir}/markDuplicates", mode: 'copy',
        saveAs: {filename -> filename.indexOf("_metrics.txt") > 0 ? "metrics/$filename" : "$filename"}

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file bam_markduplicates

    output:
    file "${bam_markduplicates.baseName}.markDups.bam" into bam_md
    file "${bam_markduplicates.baseName}.markDups_metrics.txt" into picard_results
    file "${bam_markduplicates.baseName}.bam.bai"
    file '.command.log' into markDuplicates_stdout

    script:
    if( task.memory == null ){
        log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
        avail_mem = 3
    } else {
        avail_mem = task.memory.toGiga()
    }
    """
    picard -Xmx${avail_mem}g MarkDuplicates \\
        INPUT=$bam_markduplicates \\
        OUTPUT=${bam_markduplicates.baseName}.markDups.bam \\
        METRICS_FILE=${bam_markduplicates.baseName}.markDups_metrics.txt \\
        REMOVE_DUPLICATES=false \\
        ASSUME_SORTED=true \\
        PROGRAM_RECORD_ID='null' \\
        VALIDATION_STRINGENCY=LENIENT

    # Print version number to standard out
    echo "File name: $bam_markduplicates Picard version "\$(picard -Xmx2g MarkDuplicates --version 2>&1)
    samtools index $bam_markduplicates
    """
}


/*
 * STEP 7 - dupRadar
 */
process dupradar {
    tag "${bam_md.baseName - '.sorted.markDups'}"
    publishDir "${params.outdir}/dupradar", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("_duprateExpDens.pdf") > 0) "scatter_plots/$filename"
            else if (filename.indexOf("_duprateExpBoxplot.pdf") > 0) "box_plots/$filename"
            else if (filename.indexOf("_expressionHist.pdf") > 0) "histograms/$filename"
            else if (filename.indexOf("_dupMatrix.txt") > 0) "gene_data/$filename"
            else if (filename.indexOf("_duprateExpDensCurve.txt") > 0) "scatter_curve_data/$filename"
            else if (filename.indexOf("_intercept_slope.txt") > 0) "intercepts_slopes/$filename"
            else "$filename"
        }

    input:
    file bam_md
    file gtf from gtf_dupradar.collect()

    output:
    file "*.{pdf,txt}" into dupradar_results
    file '.command.log' into dupradar_stdout

    script:
    """
    dupRadar.r $bam_md $gtf 'TRUE'
    """
}


/*
 * STEP 8 Feature counts
 */
process featureCounts {
    tag "${bam_featurecounts.baseName - '.sorted'}"
    publishDir "${params.outdir}/featureCounts", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("_biotype_counts_mqc.txt") > 0) "biotype_counts/$filename"
            else if (filename.indexOf("_gene.featureCounts.txt.summary") > 0) "gene_count_summaries/$filename"
            else if (filename.indexOf("_gene.featureCounts.txt") > 0) "gene_counts/$filename"
            else "$filename"
        }

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file bam_featurecounts
    file gtf from gtf_featureCounts.collect()
    file biotypes_header

    output:
    file "${bam_featurecounts.baseName}_gene.featureCounts.txt" into geneCounts, featureCounts_to_merge
    file "${bam_featurecounts.baseName}_gene.featureCounts.txt.summary" into featureCounts_logs
    file "${bam_featurecounts.baseName}_biotype_counts_mqc.txt" into featureCounts_biotype
    file '.command.log' into featurecounts_stdout

    script:
    def featureCounts_direction = 0
    if (forward_stranded && !unstranded) {
        featureCounts_direction = 1
    } else if (reverse_stranded && !unstranded){
        featureCounts_direction = 2
    }
    """
    featureCounts -a $gtf -g gene_id -o ${bam_featurecounts.baseName}_gene.featureCounts.txt -p -s $featureCounts_direction $bam_featurecounts
    featureCounts -a $gtf -g gene_biotype -o ${bam_featurecounts.baseName}_biotype.featureCounts.txt -p -s $featureCounts_direction $bam_featurecounts
    cut -f 1,7 ${bam_featurecounts.baseName}_biotype.featureCounts.txt | tail -n 7 > tmp_file
    cat $biotypes_header tmp_file >> ${bam_featurecounts.baseName}_biotype_counts_mqc.txt
    """
}


/*
 * STEP 9 - Merge featurecounts
 */
process merge_featureCounts {
    tag "${input_files[0].baseName - '.sorted'}"
    publishDir "${params.outdir}/featureCounts", mode: 'copy'

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file input_files from featureCounts_to_merge.collect()

    output:
    file 'merged_gene_counts.txt'

    script:
    """
    merge_featurecounts.py -o merged_gene_counts.txt -i $input_files
    """
}


/*
 * STEP 10 - stringtie FPKM
 */
process stringtieFPKM {
    tag "${bam_stringtieFPKM.baseName - '.sorted'}"
    publishDir "${params.outdir}/stringtieFPKM", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("transcripts.gtf") > 0) "transcripts/$filename"
            else if (filename.indexOf("cov_refs.gtf") > 0) "cov_refs/$filename"
            else "$filename"
        }

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file bam_stringtieFPKM
    file gtf from gtf_stringtieFPKM.collect()

    output:
    file "${bam_stringtieFPKM.baseName}_transcripts.gtf"
    file "${bam_stringtieFPKM.baseName}.gene_abund.txt"
    file "${bam_stringtieFPKM}.cov_refs.gtf"
    file ".command.log" into stringtie_log, stringtie_stdout

    script:
    def st_direction = ''
    if (forward_stranded && !unstranded){
        st_direction = "--fr"
    } else if (reverse_stranded && !unstranded){
        st_direction = "--rf"
    }
    """
    stringtie $bam_stringtieFPKM \\
        $st_direction \\
        -o ${bam_stringtieFPKM.baseName}_transcripts.gtf \\
        -v \\
        -G $gtf \\
        -A ${bam_stringtieFPKM.baseName}.gene_abund.txt \\
        -C ${bam_stringtieFPKM}.cov_refs.gtf \\
        -e \\
        -b ${bam_stringtieFPKM.baseName}_ballgown

    echo "File name: $bam_stringtieFPKM Stringtie version "\$(stringtie --version)
    """
}
def num_bams
bam_count.count().subscribe{ num_bams = it }

/*
 * STEP 11 - edgeR MDS and heatmap
 */
process sample_correlation {
    tag "${input_files[0].toString() - '.sorted_gene.featureCounts.txt' - 'Aligned'}"
    publishDir "${params.outdir}/sample_correlation", mode: 'copy'

    input:
    file input_files from geneCounts.collect()
    bam_count
    file mdsplot_header
    file heatmap_header
    output:
    file "*.{txt,pdf,csv}" into sample_correlation_results

    when:
    num_bams > 2 && (!params.sampleLevel)

    script: // This script is bundled with the pipeline, in RNAseq/bin/
    """
    edgeR_heatmap_MDS.r $input_files
    cat $mdsplot_header edgeR_MDS_Aplot_coordinates_mqc.csv >> tmp_file
    mv tmp_file edgeR_MDS_Aplot_coordinates_mqc.csv
    cat $heatmap_header log2CPM_sample_distances_mqc.csv >> tmp_file
    mv tmp_file log2CPM_sample_distances_mqc.csv
    """
}

/*
 * Parse software version numbers
 */
software_versions = [
  'FastQC': null, 'Trim Galore!': null, 'Star': null, 'HISAT2': null, 'StringTie': null,
  'Preseq': null, 'featureCounts': null, 'dupRadar': null, 'Picard MarkDuplicates': null,
  'Nextflow': "v$workflow.nextflow.version"
]
if(params.aligner == 'star') software_versions.remove('HISAT2')
else if(params.aligner == 'hisat2') software_versions.remove('Star')

process get_software_versions {
    cache false
    executor 'local'

    input:
    val fastqc from fastqc_stdout.collect()
    val trim_galore from trimgalore_logs.collect()
    val star from star_log.collect()
    val stringtie from stringtie_stdout.collect()
    val hisat from hisat_stdout.collect()
    val preseq from preseq_stdout.collect()
    val featurecounts from featurecounts_stdout.collect()
    val dupradar from dupradar_stdout.collect()
    val markDuplicates from markDuplicates_stdout.collect()

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    exec:
    software_versions['FastQC'] = fastqc[0].getText().find(/FastQC v(\S+)/) { match, version -> "v$version" }
    software_versions['Trim Galore!'] = trim_galore[0].getText().find(/Trim Galore version: (\S+)/) {match, version -> "v$version"}
    if(params.aligner == 'star') software_versions['Star'] = star[0].getText().find(/STAR_(\d+\.\d+\.\d+)/) { match, version -> "v$version" }
    else if(params.aligner == 'hisat2') software_versions['HISAT2'] = hisat[0].getText().find(/hisat2\S+ version (\S+)/) { match, version -> "v$version" }
    software_versions['StringTie'] = stringtie[0].getText().find(/StringTie (\S+)/) { match, version -> "v"+version.replaceAll(/\.$/, "") }
    software_versions['Preseq'] = preseq[0].getText().find(/Version: (\S+)/) { match, version -> "v$version" }
    software_versions['featureCounts'] = featurecounts[0].getText().find(/\s+v([\.\d]+)/) {match, version -> "v$version"}
    software_versions['dupRadar'] = dupradar[0].getText().find(/dupRadar\_(\S+)/) {match, version -> "v$version"}
    software_versions['Picard MarkDuplicates'] = markDuplicates[0].getText().find(/Picard version ([\d\.]+)/) {match, version -> "v$version"}

    def sw_yaml_file = task.workDir.resolve('software_versions_mqc.yaml')
    sw_yaml_file.text  = """
    id: 'rnaseq'
    section_name: 'RNAseq Software Versions'
    section_href: 'https://github.com/cellgeni/RNAseq'
    plot_type: 'html'
    description: 'are collected at run time from the software output.'
    data: |
        <dl class=\"dl-horizontal\">
${software_versions.collect{ k,v -> "            <dt>$k</dt><dd>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</dd>" }.join("\n")}
        </dl>
    """.stripIndent()
}

/*
 * STEP 12 MultiQC
 */
process multiqc {
    tag "$prefix"
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    beforeScript "set +u; source activate rnaseq${version}"
    afterScript "set +u; source deactivate"

    input:
    file multiqc_config
    file (fastqc:'fastqc/*') from fastqc_results.collect()
    file ('trimgalore/*') from trimgalore_results.collect()
    file ('alignment/*') from alignment_logs.collect()
    file ('rseqc/rseqc_log.*') from rseqc_results.collect()
    file ('rseqc/genebody_*') from genebody_coverage_results.collect()
    file ('preseq/*') from preseq_results.collect()
    file ('dupradar/*') from dupradar_results.collect()
    file ('featureCounts/*') from featureCounts_logs.collect()
    file ('featureCounts_biotype/*') from featureCounts_biotype.collect()
    file ('stringtie/stringtie_log*') from stringtie_log.collect()
    file ('sample_correlation_results/*') from sample_correlation_results.collect()
    file ('software_versions/*') from software_versions_yaml

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"
    file '.command.err' into multiqc_stderr
    val prefix into multiqc_prefix

    script:
    prefix = fastqc[0].toString() - '_fastqc.html' - 'fastqc/'
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}
multiqc_stderr.subscribe { stderr ->
  software_versions['MultiQC'] = stderr.getText().find(/This is MultiQC v(\S+)/) { match, version -> "v$version" }
}

/*
 * STEP 13 - Output Description HTML
 */
process output_documentation {
    tag "$prefix"
    publishDir "${params.outdir}/Documentation", mode: 'copy'

    input:
    file output_docs
    val prefix from multiqc_prefix

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}
