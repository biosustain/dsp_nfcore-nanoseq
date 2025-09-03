/*
 * Merge the fastq files
 * from the same barcode
 * into one file
 * to get input files in consisten order they are inputted as input
 * so they get consistent order in unix
 */

// this one could be nf-core module, the rest are more internal usage

process mergeFiles{
        container 'jbjespersen/parquet:test'
        publishDir(
           path: "${params.publishDir}/fastq_merged",
           overwrite: true,
                mode: 'copy'
        )
        input:
                tuple val(dir), path(files, stageAs: 'inputs/*')
        output:
                path "merged_${dir.replaceAll('.*/', '')}.fastq.gz"
        script:
        """
        cat inputs/* > merged_${dir.replaceAll('.*/', '')}.fastq.gz
        """
}
