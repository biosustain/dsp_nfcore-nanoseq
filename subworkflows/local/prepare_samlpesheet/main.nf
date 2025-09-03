include { getParquet } from '../../../modules/local/get_parquet/main.nf'
include { setReferences } from '../../../modules/local/set_references/main.nf'
include { fileDir } from '../../../modules/local/file_dir/main.nf'
include { mergeFiles } from '../../../modules/local/merge_files/main.nf'
include { collectSampleInput } from '../../../modules/local/collect_sample_input/main.nf'

workflow prepare_samplesheet{
        parquetFile = file(params.parquetpath)
        getParquet(parquetFile)
        setReferences(params.reference)
        def fasta = setReferences.out.fasta
        def gtf = setReferences.out.gtf
        def path = params.parquetpath
        def samples = getParquet.out
        .splitCsv(header: true)
        samples.view()
        def pairedChannel = samples.map { sampleRow -> [sampleRow, path] }

        // throw an error if the flowcell field is empty ?
        fileDir(pairedChannel)
        // commented out below to match all flowcell folders instead of from parquet metadata (works when empty field)
        fastqs = fileDir.out
        .map { barcode, baseDir, expFolder, flowcell ->
        //     "${baseDir}/${expFolder}/${expFolder}/*_${flowcell}_*/fastq_pass/barcode${barcode}"
            "${baseDir}/${expFolder}/${expFolder}/*/fastq_pass/barcode${barcode}"
        }
        fastqs.view()
        dir_files_ch = fastqs.map { dir -> tuple(dir, file("${dir}/*")) }
        mergeFiles(dir_files_ch)
        collectSampleInput(samples,mergeFiles.out,fasta,gtf,params.publishDir)
        Channel.value ('group,replicate,barcode,input_file,fasta,gtf')
        .concat( collectSampleInput.out)
        .collectFile(name: "${params.publishDir}/samplesheet_test.csv", sort: false, newLine: true)
}

