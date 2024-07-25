# Copyright 2023 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#!/usr/bin/env bash
set -xeuo pipefail

github_org=kubernetes
github_repo=k8s.io
github_branch=main

if ! command -v flux &> /dev/null
then
  echo "flux could not be found"
  exit 2
fi

if [ -z $PROW_ENV ]; then
  echo "PROW_ENV environment variable is not set. It must be set to canary or prod"
  exit 3
fi

UPDATE_FLUX=${UPDATE_FLUX:-false}

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

function boilerplate() {
  cat ${script_root}/../../../../../hack/boilerplate/boilerplate.sh.txt | sed -e "s/\<YEAR\>/$(date +'%Y')/"
  echo "# Code generated by make flux-update. DO NOT EDIT."
}

resources_dir=${script_root}/../resources

if [ "$UPDATE_FLUX" = true ]; then
# Generate all FluxCD resources.
# gotk stands for GitOpsToolKit (https://fluxcd.io/flux/components/)
boilerplate > ${resources_dir}/flux/gotk-components.yaml
flux install --export >> ${resources_dir}/flux/gotk-components.yaml
else
  echo "Skipping updating Flux because the UPDATE_FLUX environment variable is not set to true"
fi

# sync_interval determines Flux Source Controller sync interval.
# (https://github.com/fluxcd/source-controller)
sync_interval=5m

boilerplate > ${resources_dir}/flux-system/flux-source-git-k8s.io.yaml
flux create source git k8s-io \
    --url=https://github.com/${github_org}/k8s.io \
    --branch=${github_branch} \
    --interval=${sync_interval} \
    --export >> ${resources_dir}/flux-system/flux-source-git-k8s.io.yaml

boilerplate > ${resources_dir}/flux-system/flux-source-helm-eks-charts.yaml
flux create source helm eks-charts \
    --url=https://aws.github.io/eks-charts \
    --interval=${sync_interval} \
    --export >> ${resources_dir}/flux-system/flux-source-helm-eks-charts.yaml

boilerplate > ${resources_dir}/kube-system/flux-hr-node-termination-handler.yaml
flux create hr node-termination-handler \
    --source=HelmRepository/eks-charts.flux-system \
    --namespace=kube-system \
    --chart=aws-node-termination-handler \
    --chart-version=0.21.0 \
    --interval=${sync_interval} \
    --export >> ${resources_dir}/kube-system/flux-hr-node-termination-handler.yaml

boilerplate > ${resources_dir}/flux-system/flux-source-helm-kubecost-chart.yaml
flux create source helm kubecost \
    --url https://kubecost.github.io/cost-analyzer \
    --interval=${sync_interval} \
    --export >> ${resources_dir}/flux-system/flux-source-helm-kubecost-chart.yaml

# Different helm values are provided canary and prod clusters via ConfigMap
kubectl create configmap kubecost-helm-values \
    --from-file=values.yaml=${resources_dir}/kubecost/${PROW_ENV}-cluster-values \
    --namespace kubecost --dry-run=client -o yaml | kubectl apply -f -

boilerplate > ${resources_dir}/kubecost/flux-hr-kubecost.yaml
flux create hr kubecost \
    --source HelmRepository/kubecost.flux-system \
    --namespace=kubecost \
    --chart cost-analyzer \
    --chart-version 2.0.1 \
    --release-name kubecost \
    --values-from=ConfigMap/kubecost-helm-values \
    --interval=${sync_interval} \
    --export >> ${resources_dir}/kubecost/flux-hr-kubecost.yaml

# This list contains names of folders inside ./resources directory
# that are used for generating FluxCD kustomizations.
kustomizations=(
    boskos
    flux
    flux-system
    kube-system
    monitoring
    node-problem-detector
    rbac
    test-pods
    external-secrets
    kubecost
    cluster-autoscaler
)

# Code below is used to figure out a relative path of
# resources dir in relation to the root dir of git repo.
pushd ${resources_dir} > /dev/null
resources_git_repo_path=$(git rev-parse --show-prefix)
popd > /dev/null

for k in "${kustomizations[@]}"; do
    boilerplate > ${resources_dir}/flux-system/flux-ks-${k}.yaml
    flux create kustomization ${k} \
        --source=GitRepository/k8s-io.flux-system \
        --path=${resources_git_repo_path}/${k} \
        --interval=5m \
        --prune \
        --export >> ${resources_dir}/flux-system/flux-ks-${k}.yaml
done
