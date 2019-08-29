#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/nanodemux
========================================================================================
 nf-core/nanodemux Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/nanodemux
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/nanodemux --samplesheet 'samplesheet.csv' -profile test,docker

    Mandatory arguments
      --samplesheet                 Comma-separated file containing information about the samples in the experiment (see docs/usage.md)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: docker, singularity, awsbatch, test and more.

    Demultiplexing
      --run_dir                     Path to Nanopore run directory (e.g. fastq_pass/)
      --flowcell                    Which flowcell was used that the sequencing was performed with (i.e FLO-MIN106)
      --kit                         The sequencing kit used (i.e. SQK-LSK109)
      --barcode_kit                 The barcoding kit used (i.e. SQK-PBK004)
      --skipDemultiplexing          Skip demultiplexing step with guppy

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --saveReference               Save the generated reference files to the results directory

    Trimming
      --skipTrimming                Skip the adapter trimming step

    Alignment
      --aligner                     Specifies the aligner to use (available are: 'graphmap', 'minimap2')
      --saveAlignedIntermediates    Save the BAM files from the aligment step - not done by default
      --skipAlignment               Skip alignment and subsequent process

    Downstream analysis
      --skipIndels                  Skip indel calling process

    QC
      --skipQC                      Skip all QC steps apart from MultiQC
      --skipPycoQC                  Skip pycoQC
      --skipNanoPlot                Skip NanoPlot
      --skipMultiQC                 Skip MultiQC

    Other
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help){
    helpMessage()
    exit 0
}

if (params.samplesheet)         { ch_samplesheet = file(params.samplesheet, checkIfExists: true) } else { exit 1, "Samplesheet file not specified!" }
if (!params.skipDemultiplexing) {
    if (params.run_dir)         { ch_run_dir = file(params.run_dir, checkIfExists: true) } else { exit 1, "Please specify a valid run directory!" }
    if (!params.flowcell)       { exit 1, "Please specify a valid flowcell identifier for demultiplexing!" }
    if (!params.kit)            { exit 1, "Please specify a valid kit identifier for demultiplexing!" }
    if (!params.barcode_kit)    { exit 1, "Please specify a valid barcode kit for demultiplexing!" }
}
if (!params.skipAlignment)      {
    if (params.aligner != 'minimap2' && params.aligner != 'graphmap'){
        exit 1, "Invalid aligner option: ${params.aligner}. Valid options: 'minimap2', 'graphmap'"
    }
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

/*
 * PREPROCESSING - CHECK SAMPLESHEET
 */
process checkSampleSheet {
    tag "$samplesheet"
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file samplesheet from ch_samplesheet

    output:
    file "*.csv" into ch_samplesheet_reformat

    script:  // This script is bundled with the pipeline, in nf-core/nanodemux/bin/
    demultipex = params.skipDemultiplexing ? "" : "--demultiplex"
    """
    check_samplesheet.py $samplesheet samplesheet_reformat.csv $demultipex
    """
}

// Function to see if genome exists in iGenomes
def get_fasta(genome, genomeMap) {
    def fasta = genome
    if (genome) {
        if (genomeMap.containsKey(genome)) {
            fasta = file(genomeMap[genome].fasta, checkIfExists: true)
        } else {
            fasta = file(genome, checkIfExists: true)
        }
    }
    return fasta
}

/*
 * Create channels for inputs
 */
if (!params.skipDemultiplexing) {
    ch_samplesheet_reformat.splitCsv(header:true, sep:',')
                       .map { row -> [ row.sample, row.barcode, get_fasta(row.genome, params.genomes) ] }
                       .set { ch_sample_info }
} else {
    ch_samplesheet_reformat.splitCsv(header:true, sep:',')
                       .map { row -> [ row.sample, file(row.fastq, checkIfExists: true), get_fasta(row.genome, params.genomes) ] }
                       .set { ch_sample_info }
}

/*
 * STEP 2 - Basecalling, demultipexing using Guppy, and QC with pycoQC and NanoPlot
 */
if (!params.skipDemultiplexing){
    process guppy {
        tag "$run_dir"
        label 'process_high'
        publishDir path: "${params.outdir}/guppy", mode: 'copy'

        input:
        file run_dir from ch_run_dir

        output:
        file "fastq_merged/*.fastq.gz" into ch_guppy_nanoplot_fastq,
                                            ch_guppy_align_fastq
        file "*.txt" into ch_guppy_pycoqc_summary,
                          ch_guppy_nanoplot_summary
        file "*.version" into ch_guppy_version
        file "barcode*"
        file "unclassified"
        file "*.{log,js}"

        script:
        """
        guppy_basecaller \\
            --input_path $run_dir \\
            --save_path . \\
            --flowcell $params.flowcell \\
            --kit $params.kit \\
            --barcode_kits $params.barcode_kit
        guppy_basecaller --version &> guppy.version

        ## Concatenate fastq files for each barcode
        mkdir fastq_merged
        for dir in barcode*/
        do
            dir=\${dir%*/}
            cat \$dir/*.fastq > fastq_merged/\$dir.fastq
        done
        gzip fastq_merged/*.fastq
        """
    }

    process pycoQC {
        tag "$summary_txt"
        label 'process_low'
        publishDir "${params.outdir}/pycoQC", mode: 'copy'

        when:
        !params.skipQC && !params.skipPycoQC

        input:
        file summary_txt from ch_guppy_pycoqc_summary

        output:
        file "*.html"
        file "*.version" into ch_pycoqc_version

        script:
        """
        pycoQC -f $summary_txt -o pycoQC_output.html
        pycoQC --version &> pycoqc.version
        """
    }

    process NanoPlot_summary {
        tag "$summary_txt"
        label 'process_low'
        publishDir "${params.outdir}/nanoplot/summary", mode: 'copy'

        when:
        !params.skipQC && !params.skipNanoPlot

        input:
        file summary_txt from ch_guppy_nanoplot_summary

        output:
        file "*.{png,html,txt,log}"

        script:
        """
        NanoPlot -t ${task.cpus} --summary $summary_txt
        """
    }
}

// NEED TO CHANGE ch_guppy_nanoplot_fastq IF INPUT IS FROM FASTQ FILES

process NanoPlot_fastq {
    //tag "$summary_txt"
    label 'process_low'
    publishDir "${params.outdir}/nanoplot/fastq", mode: 'copy'

    when:
    !params.skipQC && !params.skipNanoPlot

    input:
    file fastq from ch_guppy_nanoplot_fastq

    output:
    file "*.{png,html,txt,log}"
    file "*.version" into ch_nanoplot_version

    script:
    """
    NanoPlot -t ${task.cpus} --fastq $fastq
    NanoPlot --version &> nanoplot.version
    """
}

// /*
//  * STEP 4 - Align fastq files and coordinate sort BAM
//  */
// if (!params.skipAlignment){
//     if(params.aligner == 'graphmap'){
//         process GraphMap {
//             tag "${fastq.baseName}"
//             label 'process_medium'
//             publishDir path: "${params.outdir}/${params.aligner}", mode: 'copy'
//
//             input:
//             file fastq from ch_guppy_align_fastq
//
//             output:
//             file "*.sam" into ch_align_sam
//             file "*.version" into ch_align_version
//
//             script:
//             """
//             graphmap align -t ${task.cpus} -r ref.fa -d $fastq -o ${fastq.baseName}.sam --extcigar
//             graphmap &> graphmap.version
//             """
//         }
//     }
//
//     if(params.aligner == 'minimap2'){
//         process minimap2 {
//             tag "${fastq.baseName}"
//             label 'process_medium'
//             publishDir path: "${params.outdir}/${params.aligner}", mode: 'copy'
//
//             input:
//             file fastq from ch_guppy_align_fastq
//
//             output:
//             file "*.sam" into ch_align_sam
//             file "*.version" into ch_align_version
//
//             script:
//             """
//             minimap2 -ax map-ont $fasta $fastq > ${fastq.baseName}.sam
//             minimap2 --version &> minimap.version
//             """
//         }
//     }
//
//     process sortBAM {
//         tag "$prefix"
//         label 'process_medium'
//         if (params.saveAlignedIntermediates) {
//             publishDir path: "${params.outdir}/${params.aligner}", mode: 'copy',
//                 saveAs: { filename ->
//                         if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
//                         else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
//                         else if (filename.endsWith(".stats")) "samtools_stats/$filename"
//                         else filename }
//         }
//
//         input:
//         file sam from ch_align_sam
//
//         output:
//         file("*.sorted.{bam,bam.bai}") into ch_sortbam_bam
//         file "*.{flagstat,idxstats,stats}" into ch_sortbam_stats
//         file "*.version" into ch_samtools_version
//
//         script:
//         prefix="${sam.baseName}"
//         """
//         samtools view -b -h -O BAM -@ $task.cpus -o ${prefix}.bam $sam
//         samtools sort -@ $task.cpus -o ${prefix}.sorted.bam -T $name ${prefix}.bam
//         samtools index ${prefix}.sorted.bam
//         samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
//         samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
//         samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
//         samtools --version &> samtools.version
//         """
//     }
// }

// /*
//  * STEP 5 - Call Indels
//  */
// process callIndels {
//     tag "$prefix"
//     label 'process_low'
//     publishDir path: "${params.outdir}/indels", mode: 'copy'
//
//     when:
//     !params.skipAlignment && !params.skipIndels
//
//     input:
//     file bam from ch_sortbam_bam
//
//     //output:
//     //set file("*.sorted.{bam,bam.bai}") into ch_sortbam_bam
//     //file "*.version" into ch_pysam_version
//
//     script:  // This script is bundled with the pipeline, in nf-core/nanodemux/bin/
//     prefix="${bam.baseName}"
//     """
//     getIndelsBAM.py $bam $fasta ${prefix}.indels.bed 0
//     """
// }

// /*
//  * Parse software version numbers
//  */
// process get_software_versions {
//     publishDir "${params.outdir}/pipeline_info", mode: 'copy',
//     saveAs: {filename ->
//         if (filename.indexOf(".csv") > 0) filename
//         else null
//     }
//
//     input:
//     file guppy from ch_guppy_version.collect().ifEmpty([])
//     file pycoqc from ch_pycoqc_version.collect().ifEmpty([])
//     file nanoplot from ch_nanoplot_version.first()
//     file align from ch_align_version.first()
//     file samtools from ch_samtools_version.first()
//     file pysam from ch_pysam_version.first()
//     file multiqc from ch_multiqc_version.collect().ifEmpty([])
//     file rmarkdown from ch_rmarkdown_version.collect().ifEmpty([])
//
//     output:
//     file 'software_versions_mqc.yaml' into software_versions_yaml
//     file "software_versions.csv"
//
//     script:
//     // TODO nf-core: Get all tools to print their version number here
//     """
//     echo $workflow.manifest.version > v_pipeline.txt
//     echo $workflow.nextflow.version > v_nextflow.txt
//     scrape_software_versions.py &> software_versions_mqc.yaml
//     """
// }

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-nanodemux-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/nanodemux Workflow Summary'
    section_href: 'https://github.com/nf-core/nanodemux'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

// /*
//  * STEP 3 - MultiQC
//  */
// process multiqc {
//     publishDir "${params.outdir}/${runName}/MultiQC", mode: 'copy'
//
//     when:
//     !params.skipMultiQC
//
//     input:
//     file summary from minion_summary
//
//     output:
//     file "*multiqc_report.html" into multiqc_report
//     file "*_data"
//     //file "*.version" into ch_multiqc_version
//
//     script:
//     """
//     multiqc $summary --config $multiqc_config .
//     multiqc --version &> multiqc.version
//     """
// }

// /*
//  * STEP 4 - Output Description HTML
//  */
// process output_documentation {
//     publishDir "${params.outdir}/pipeline_info", mode: 'copy'
//
//     input:
//     file output_docs from ch_output_docs
//
//     output:
//     file "results_description.html"
//     //file "*.version" into ch_rmarkdown_version
//
//     script:
//     """
//     markdown_to_html.r $output_docs results_description.html
//     Rscript -e "library(markdown); write(x=as.character(packageVersion('markdown')), file='markdown.version')"
//     """
// }

// /*
//  * Completion e-mail notification
//  */
// workflow.onComplete {
//
//     // Set up the e-mail variables
//     def subject = "[nf-core/nanodemux] Successful: $workflow.runName"
//     if(!workflow.success){
//       subject = "[nf-core/nanodemux] FAILED: $workflow.runName"
//     }
//     def email_fields = [:]
//     email_fields['version'] = workflow.manifest.version
//     email_fields['runName'] = custom_runName ?: workflow.runName
//     email_fields['success'] = workflow.success
//     email_fields['dateComplete'] = workflow.complete
//     email_fields['duration'] = workflow.duration
//     email_fields['exitStatus'] = workflow.exitStatus
//     email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
//     email_fields['errorReport'] = (workflow.errorReport ?: 'None')
//     email_fields['commandLine'] = workflow.commandLine
//     email_fields['projectDir'] = workflow.projectDir
//     email_fields['summary'] = summary
//     email_fields['summary']['Date Started'] = workflow.start
//     email_fields['summary']['Date Completed'] = workflow.complete
//     email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
//     email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
//     if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
//     if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
//     if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
//     if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
//     email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
//     email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
//     email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp
//
//     // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
//     // On success try attach the multiqc report
//     def mqc_report = null
//     try {
//         if (workflow.success) {
//             mqc_report = multiqc_report.getVal()
//             if (mqc_report.getClass() == ArrayList){
//                 log.warn "[nf-core/nanodemux] Found multiple reports from process 'multiqc', will use only one"
//                 mqc_report = mqc_report[0]
//             }
//         }
//     } catch (all) {
//         log.warn "[nf-core/nanodemux] Could not attach MultiQC report to summary email"
//     }
//
//     // Render the TXT template
//     def engine = new groovy.text.GStringTemplateEngine()
//     def tf = new File("$baseDir/assets/email_template.txt")
//     def txt_template = engine.createTemplate(tf).make(email_fields)
//     def email_txt = txt_template.toString()
//
//     // Render the HTML template
//     def hf = new File("$baseDir/assets/email_template.html")
//     def html_template = engine.createTemplate(hf).make(email_fields)
//     def email_html = html_template.toString()
//
//     // Render the sendmail template
//     def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
//     def sf = new File("$baseDir/assets/sendmail_template.txt")
//     def sendmail_template = engine.createTemplate(sf).make(smail_fields)
//     def sendmail_html = sendmail_template.toString()
//
//     // Send the HTML e-mail
//     if (params.email) {
//         try {
//           if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
//           // Try to send HTML e-mail using sendmail
//           [ 'sendmail', '-t' ].execute() << sendmail_html
//           log.info "[nf-core/nanodemux] Sent summary e-mail to $params.email (sendmail)"
//         } catch (all) {
//           // Catch failures and try with plaintext
//           [ 'mail', '-s', subject, params.email ].execute() << email_txt
//           log.info "[nf-core/nanodemux] Sent summary e-mail to $params.email (mail)"
//         }
//     }
//
//     // Write summary e-mail HTML to a file
//     def output_d = new File( "${params.outdir}/pipeline_info/" )
//     if( !output_d.exists() ) {
//       output_d.mkdirs()
//     }
//     def output_hf = new File( output_d, "pipeline_report.html" )
//     output_hf.withWriter { w -> w << email_html }
//     def output_tf = new File( output_d, "pipeline_report.txt" )
//     output_tf.withWriter { w -> w << email_txt }
//
//     c_reset = params.monochrome_logs ? '' : "\033[0m";
//     c_purple = params.monochrome_logs ? '' : "\033[0;35m";
//     c_green = params.monochrome_logs ? '' : "\033[0;32m";
//     c_red = params.monochrome_logs ? '' : "\033[0;31m";
//
//     if (workflow.stats.ignoredCountFmt > 0 && workflow.success) {
//       log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
//       log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
//       log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
//     }
//
//     if(workflow.success){
//         log.info "${c_purple}[nf-core/nanodemux]${c_green} Pipeline completed successfully${c_reset}"
//     } else {
//         checkHostname()
//         log.info "${c_purple}[nf-core/nanodemux]${c_red} Pipeline completed with errors${c_reset}"
//     }
//
// }


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/nanodemux v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

// def get_nanopore_info(csv){
//   def start = 0
//   def end = 3
//   csv.eachLine(start) { line, lineNo ->
//     if (lineNo <= end) {
//           def parts = line.split(",")
//       if (parts[0] == "Flowcell") {
//         flowcell = parts[1];
//       }
//       else if(parts[0] == "Kit") {
//         kit = parts[1];
//       }
//       else if(parts[0] == "Barcode_kit") {
//         barcode_kit = parts[1];
//       }
//       }
//   }
//   return [flowcell, kit, barcode_kit]
// }
//
// def (flowcell, kit, barcode_kit) = get_nanopore_info(params.samplesheet)
