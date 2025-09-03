/*
 * Collect the new file paths and metadata
 * to create individual lines for each sample to go into the samplesheet
 */

process collectSampleInput{
        container 'jbjespersen/parquet:test'
        input:
                val(sample) 
                path(mergedFile) 
                val(fasta) 
                val(gtf)
                val(publishDir)
        output:
                env (sampleLine)
        script:
        def sampleLine = "${sample.group},${sample.replicate},,${publishDir}/fastq_merged/${mergedFile},${fasta},${gtf}"
        """
        sampleLine="${sample.group},${sample.replicate},,${publishDir}/fastq_merged/${mergedFile},${fasta},${gtf}"
        """
        }