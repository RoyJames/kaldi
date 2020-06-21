#!/bin/bash

# Copyright 2012  Arnab Ghoshal
# Copyright 2010-2011  Microsoft Corporation

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
# WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
# MERCHANTABLITY OR NON-INFRINGEMENT.
# See the Apache 2 License for the specific language governing permissions and
# limitations under the License.

# To be run from ..
# Triphone model training, using (e.g. MFCC) + delta + acceleration features and
# cepstral mean normalization.  It starts from an existing directory (e.g.
# exp/mono), supplied as an argument, which is assumed to be built using the same
# type of features.
#
# This script starts from previously generated state-level alignments
# (in $alidir), e.g. generated by a previous monophone or triphone
# system.  To build a context-dependent triphone system, we build 
# decision trees that map a 3-phone phonetic context window to a
# pdf index.  It's not really clear which is the right reference, but
# on is "Tree-based state tying for high accuracy acoustic modelling"
# by Steve Young et al.  
# In a typical approach, there are decision trees for
# each monophone HMM-state (i.e. 3 per phone), and each one gets to
# ask questions about the left and right phone.  These questions
# correspond to sets of phones, corresponding to phonetic classes
# (e.g. vowel, consonant, liquid, solar, ... ).  In Kaldi, we prefer
# fully automatic algorithms, and anyway we're not sure where to get
# these types of lists, so we just generate the classes automatically.
# This is based on a top-down binary tree clustering of the phones
# (see "cluster-phones"), where we take single-Gaussian statistics for 
# just the central state of each phone (assuming this to be more 
# representative of the phones), and we get a tree structure on the
# phones; each class corresponds to a node of the tree (it contains all 
# the phones that are children of that node).  Note: you could
# replace questions.txt with something derived from manually written
# questions.
#  Also, the roots of the tree correspond to classes of phones (typically
# corresponding to "real phones", because the actual phones may contain
# word-begin/end and stress information), and the tree gets to ask
# questions also about the central phone, and about the state in the HMM.
#  After building the tree, we do a number of iterations of Gaussian
# Mixture Model training; on selected iterations we redo the Viterbi
# alignments (initially, these are taken from the previous system).
# The Gaussian mixture splitting, whereby we go from a single Gaussian
# per state to multiple Gaussians, is done on all iterations (although
# we stop doing this a few iterations before the end).  We don't have
# a fixed number of Gaussians per state, but we have an overall target
# #Gaussians that's specified on each iteration, and we allocate
# the Gaussians among states according to a power-law where the #Gaussians
# is proportional to the count to the power 0.2.  The target
# increases linearly during training [note: logarithmically seems more
# natural but didn't work as well.]

function error_exit () {
  echo -e "$@" >&2; exit 1;
}

function readint () {
  local retval=${1/#*=/};  # In case --switch=ARG format was used
  retval=${retval#0*}      # Strip any leading 0's
  [[ "$retval" =~ ^-?[1-9][0-9]*$ ]] \
    || error_exit "Argument \"$retval\" not an integer."
  echo $retval
}

nj=4       # Default number of jobs
qcmd=""    # Options for the submit_jobs.sh script
sjopts=""  # Options for the submit_jobs.sh script

PROG=`basename $0`;
usage="Usage: $PROG [options] <num-leaves> <data-dir> <lang-dir> <ali-dir> <exp-dir>\n
e.g.: $PROG 2000 data/train_si84 data/lang exp/mono_ali exp/tri1\n\n
Options:\n
  --help\t\tPrint this message and exit\n
  --num-jobs INT\tNumber of parallel jobs to run (default=$nj).\n
  --qcmd STRING\tCommand for submitting a job to a grid engine (e.g. qsub) including switches.\n
  --sjopts STRING\tOptions for the 'submit_jobs.sh' script\n
";

while [ $# -gt 0 ]; do
  case "${1# *}" in  # ${1# *} strips any leading spaces from the arguments
    --help) echo -e $usage; exit 0 ;;
    --num-jobs) 
      shift; nj=`readint $1`;
      [ $nj -lt 1 ] && error_exit "--num-jobs arg '$nj' not positive.";
      shift ;;
    --qcmd)
      shift; qcmd=" --qcmd=${1}"; shift ;;
    --sjopts)
      shift; sjopts="$1"; shift ;;
    -*)  echo "Unknown argument: $1, exiting"; echo -e $usage; exit 1 ;;
    *)   break ;;   # end of options: interpreted as num-leaves
  esac
done

if [ $# != 5 ]; then
  error_exit $usage;
fi

[ -f path.sh ] && . ./path.sh

numleaves=$1
data=$2
lang=$3
alidir=$4
dir=$5

if [ ! -f $alidir/final.mdl ]; then
  echo "Error: alignment dir $alidir does not contain final.mdl"
  exit 1;
fi

silphonelist=`cat $lang/silphones.csl`

mkdir -p $dir/log
if [ ! -d $data/split$nj -o $data/split$nj -ot $data/feats.scp ]; then
  split_data.sh $data $nj
fi

featspart="ark,s,cs:apply-cmvn --norm-vars=false --utt2spk=ark:$data/split$nj/TASK_ID/utt2spk ark:$alidir/TASK_ID.cmvn scp:$data/split$nj/TASK_ID/feats.scp ark:- | add-deltas ark:- ark:- |"

# The next stage assumes we won't need the context of silence, which
# assumes something about $lang/roots.txt, but it seems pretty safe.
echo "Accumulating tree stats"
submit_jobs.sh "$qcmd" --njobs=$nj --log=$dir/log/acc_tree.TASK_ID.log \
  $sjopts acc-tree-stats --ci-phones=$silphonelist $alidir/final.mdl \
  "$featspart" "ark:gunzip -c $alidir/TASK_ID.ali.gz|" $dir/TASK_ID.treeacc \
  || error_exit "Error accumulating tree stats";
sum-tree-stats $dir/treeacc $dir/*.treeacc 2>$dir/log/sum_tree_acc.log \
  || error_exit "Error summing tree stats.";
rm $dir/*.treeacc

# preparing questions, roots file...
echo "Computing questions for tree clustering"
( set -e
  sym2int.pl $lang/phones.txt $lang/phonesets_cluster.txt > $dir/phonesets.txt
  cluster-phones $dir/treeacc $dir/phonesets.txt $dir/questions.txt \
    2> $dir/log/questions.log
  [ -f $lang/extra_questions.txt ] && sym2int.pl $lang/phones.txt \
    $lang/extra_questions.txt >> $dir/questions.txt
  compile-questions $lang/topo $dir/questions.txt $dir/questions.qst \
    2>$dir/log/compile_questions.log
  sym2int.pl --ignore-oov $lang/phones.txt $lang/roots.txt > $dir/roots.txt
) || error_exit "Error in generating questions for tree clustering."

echo "Building tree"
submit_jobs.sh "$qcmd" --log=$dir/log/train_tree.log $sjopts \
  build-tree --verbose=1 --max-leaves=$numleaves $dir/treeacc $dir/roots.txt \
    $dir/questions.qst $lang/topo $dir/tree \
    || error_exit "Error in building tree.";
echo $numleaves > $dir/numleaves

# Print out summary of the warning messages.
for x in $dir/log/*.log; do 
  n=`grep WARNING $x | wc -l`; 
  if [ $n -ne 0 ]; then echo $n warnings in $x; fi; 
done

echo Done
