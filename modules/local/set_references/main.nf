
/*
* Set reference files for the pipeline
* by setting the fasta and gtf file paths
*/
process setReferences{
        container 'jbjespersen/parquet:test'
        input:
                val referenceID
        output:
                env (fasta), emit: fasta
                env (gtf), emit: gtf
        script:
        def baseRefPath = params.baseRefPath
        """
        fasta=${baseRefPath}/${referenceID}.fasta
        gtf=${baseRefPath}/${referenceID}.gtf
        """
}
