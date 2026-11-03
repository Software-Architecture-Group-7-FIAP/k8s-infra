locals {
  newrelic_nri_bundle_chart_path   = "/tmp/auto-shop-newrelic-chart/nri-bundle-8.0.39.tgz"
  newrelic_nri_bundle_chart_sha256 = "96eb019f7c78e1e746e0ba170b7e656e437ae3f7bfe7203f812e750511db108f"
}

resource "helm_release" "new_relic_hml" {
  name             = "auto-shop-new-relic"
  chart            = local.newrelic_nri_bundle_chart_path
  namespace        = "auto-shop-hml"
  create_namespace = false
  atomic           = true
  wait             = true
  timeout          = 600

  values = [file("${path.module}/newrelic-hml-values.yaml")]

  lifecycle {
    precondition {
      condition = fileexists(local.newrelic_nri_bundle_chart_path) ? filesha256(local.newrelic_nri_bundle_chart_path) == local.newrelic_nri_bundle_chart_sha256 : false
      error_message = "Prepare and verify nri-bundle 8.0.39 with scripts/prepare-newrelic-chart.sh before planning or applying the HML platform stack."
    }
  }
}
