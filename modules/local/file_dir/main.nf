/*
 * Extract the file paths for the fastq files
 * from the parquet file path
 * using regex
 */

// def makes local var, then not needed in bash.

process fileDir{
        container 'jbjespersen/parquet:test'
        input:
                tuple val(sample), val(parquetpath)
        output:
                tuple env(formattedBarcode), env(baseDir), env(expFolder), env(flowcell)
        script:
        def path = parquetpath
        def regex = /^(.+?)\/([A-Z0-9]+)\/benchling/
        def baseDir = (path =~ regex)[0][1]
        def expFolder = (path =~ regex)[0][2]
        def formattedBarcode = String.format("%02d", sample.sample_barcode as Integer)
        def flowcell = sample.flow_cell_id
                """
                formattedBarcode=${formattedBarcode}
                baseDir=${baseDir}
                expFolder=${expFolder}
                flowcell=${flowcell}
                """
}
