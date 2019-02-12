#!/bin/bash -e

mkdir -p /etc/bashrc.d

#----------------------------------------------------------------------------------------#
#
#   Script that sets up Nsight Compute
#
#----------------------------------------------------------------------------------------#

cat << EOF > /etc/profile.d/cuda-path.sh
#!/bin/sh

PATH=/usr/local/cuda/bin:/usr/local/cuda/NsightCompute-1.0:\${PATH}
export PATH

EOF

#----------------------------------------------------------------------------------------#
#
#   Script that sets up conda
#
#----------------------------------------------------------------------------------------#

cat << EOF > /etc/profile.d/conda-path.sh
#!/bin/bash

PATH=/opt/conda/bin:\${PATH}
export PATH
source activate base

EOF

#----------------------------------------------------------------------------------------#
#
#   Script that sets up tomopy
#
#----------------------------------------------------------------------------------------#

cat << EOF > /etc/bashrc.d/tomopy-conda-path.sh
#!/bin/bash

if [ -z "\$(which conda)" ]; then
   . /etc/profile.d/conda-path.sh
fi

source activate tomopy

EOF
