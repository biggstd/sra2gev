#!/usr/bin/env nextflow


local_samples = Channel
  .fromPath( params.local_samples_path )


remote_sra_ids = Channel
  .from( file(params.sra_list_path).readLines() )


process fastq_dump {

  module 'sratoolkit'
  publishDir "$sra_id", mode: 'link'
  time '24h'

  input:
    val sra_id from remote_sra_ids

  output:
    set val( sra_id ), file("${sra_id}_{1,2}.fastq") into raw_fastq

  """
  fastq-dump --split-files $sra_id
  """
}



process parse_local_sra {


  input:
    val sra_filename from local_samples

  output:
    set stdout, val("${sra_filename}") into local_raw_fastq

    """
    #!/usr/bin/python

    import os
    import sys

    base_filename = os.path.basename("$sra_filename")
    srr_name = base_filename.split('_')[0]

    sys.stdout.write(srr_name)
    """
}


combined_fastq = raw_fastq.join( local_raw_fastq )



process test_out {

  echo true
  stageInMode "link"

  input:
    set val(sra_id), file(sra_file) from combined_fastq

  """
  #!/usr/bin/python

  print("$sra_id")
  print("$sra_file")

  """

}






// process trim_test {
//
//   echo true
//
//   publishDir "$x[0]", mode: 'link'
//
//   input:
//     val x from local_samples
//
//   output:
//     stdout trim_test_out
//
//   """
//   #!/usr/bin/python
//
//   import os
//   import sys
//
//   base_filename = os.path.basename("$x")
//   srr_name = base_filename.split('_')[0]
//
//   sys.stdout.write(srr_name)
//   """
// }
//
//
//
// process test_again {
//
//   echo true
//
//   input:
//     val x from trim_test_out
//
//   """
//   #!/usr/bin/python
//
//   print("$x")
//
//   """
// }
