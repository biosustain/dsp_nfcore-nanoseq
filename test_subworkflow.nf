//under development
include { prepare_samplesheet } from './subworkflows/local/prepare_samplesheet/main.nf'

workflow TEST_SUBWORKFLOW {
    
    ch_parquet = Channel.fromPath(params.parquet_path)
        .map { path -> [['id': path.baseName], path] }
    
    prepare_samplesheet(
        ch_parquet,
        params.reference,
        params.baseRefPath,
        params.publishDir
    )
    
    prepare_samplesheet.out.samplesheet.view { meta, samplesheet ->
        "Generated samplesheet: ${samplesheet}"
    }
}