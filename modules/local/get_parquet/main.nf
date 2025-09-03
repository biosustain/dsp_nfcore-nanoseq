/*
 * Benchling metadata extraction from 
 * parquet to csv and sanitise barcode input
 * by stripping letters from column 3 (sample_barcode)
 */

 // get flowcell ID from parquet file

process getParquet{
        container 'jbjespersen/parquet:test'
        input:
                path parquetpath
        output:
                path "sample_data_1.csv"
        script:
        """
        parquet-tools csv --columns group,replicate,sample_barcode,flow_cell_id,nucleic_acid_type nanopore_sequencing_submission_sample.parquet > sample_data.csv
        head -n 1 sample_data.csv > sample_data_1.csv
        awk -F ',' -v OFS=',' 'FNR == 1 {next} { sub("[a-zA-Z]+", "", \$3); print }' sample_data.csv >> sample_data_1.csv
        """
}