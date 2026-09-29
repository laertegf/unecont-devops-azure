#!/usr/bin/env bash
# Remove o cluster kind local (e tudo que está nele).
set -Eeuo pipefail
kind delete cluster --name realworld
