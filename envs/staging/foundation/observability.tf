data "aws_eks_addon_version" "cloudwatch_observability" {
  addon_name         = "amazon-cloudwatch-observability"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

data "aws_iam_policy_document" "cloudwatch_observability_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/${var.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["amazon-cloudwatch"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["cloudwatch-agent"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_observability" {
  name                 = "auto-shop-staging-cloudwatch-observability"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.cloudwatch_observability_trust.json
  permissions_boundary = local.project_boundary_arn
}

data "aws_iam_policy_document" "cloudwatch_observability" {
  statement {
    sid       = "PublishContainerMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadNodeStorageMetadata"
    actions   = ["ec2:DescribeTags", "ec2:DescribeVolumes"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cloudwatch_observability" {
  name   = "auto-shop-staging-cloudwatch-observability"
  role   = aws_iam_role.cloudwatch_observability.id
  policy = data.aws_iam_policy_document.cloudwatch_observability.json
}

locals {
  cloudwatch_cluster_arn_suffix = split(":loadbalancer/", module.alb.alb_arn)[1]

  cloudwatch_target_group_metrics = concat(
    [
      for env, target_group_arn in module.alb.target_group_arns : [
        "AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.cloudwatch_cluster_arn_suffix,
        "TargetGroup", split(":targetgroup/", target_group_arn)[1],
        { stat = "Average", label = "${upper(env)} healthy targets" }
      ]
    ],
    [
      for env, target_group_arn in module.alb.target_group_arns : [
        "AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.cloudwatch_cluster_arn_suffix,
        "TargetGroup", split(":targetgroup/", target_group_arn)[1],
        { stat = "Maximum", label = "${upper(env)} unhealthy targets" }
      ]
    ],
    [
      for env, target_group_arn in module.alb.target_group_arns : [
        "AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.cloudwatch_cluster_arn_suffix,
        "TargetGroup", split(":targetgroup/", target_group_arn)[1],
        { stat = "Average", label = "${upper(env)} target latency" }
      ]
    ]
  )
}

resource "aws_cloudwatch_metric_alarm" "eks_api_server_5xx" {
  alarm_name          = "${var.name}-api-server-5xx"
  alarm_description   = "EKS API server returned at least one 5xx request in the last minute."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "apiserver_request_total_5XX"
  namespace           = "AWS/EKS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.name
  }
}

resource "aws_cloudwatch_metric_alarm" "eks_unschedulable_pods" {
  alarm_name          = "${var.name}-unschedulable-pods"
  alarm_description   = "EKS scheduler kept at least one pod unschedulable in two consecutive minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "scheduler_pending_pods_UNSCHEDULABLE"
  namespace           = "AWS/EKS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.name
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  for_each = var.environments

  alarm_name          = "${var.name}-${each.key}-alb-unhealthy-targets"
  alarm_description   = "${upper(each.key)} ALB target group has at least one unhealthy target. Requires traffic for target-health metrics to be emitted."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.cloudwatch_cluster_arn_suffix
    TargetGroup  = split(":targetgroup/", module.alb.target_group_arns[each.key])[1]
  }
}

resource "aws_cloudwatch_metric_alarm" "hpa_scaling_limited" {
  alarm_name          = "${var.name}-hpa-scaling-limited"
  alarm_description   = "A workload HPA in HML or PRD has been scaling-limited for five minutes."
  evaluation_interval = 60

  evaluation_criteria {
    promql_criteria {
      query           = "kube_horizontalpodautoscaler_status_condition{namespace=~\"${join("|", local.app_namespaces)}\",condition=\"ScalingLimited\",status=\"true\",\"@resource.k8s.cluster.name\"=\"${var.name}\"} == 1"
      pending_period  = 300
      recovery_period = 180
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "failed_workload_pods" {
  alarm_name          = "${var.name}-failed-workload-pods"
  alarm_description   = "A workload pod in HML or PRD is in Failed phase."
  evaluation_interval = 60

  evaluation_criteria {
    promql_criteria {
      query           = "kube_pod_status_phase{namespace=~\"${join("|", local.app_namespaces)}\",phase=\"Failed\",\"@resource.k8s.cluster.name\"=\"${var.name}\"} == 1"
      pending_period  = 120
      recovery_period = 120
    }
  }
}

resource "aws_cloudwatch_dashboard" "staging" {
  dashboard_name = "${var.name}-operations"

  dashboard_body = jsonencode({
    start          = "-PT6H"
    periodOverride = "auto"
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# EKS staging operations\nHML and PRD share this EKS cluster but use separate namespaces and ALB target groups. Control-plane metrics are free AWS/EKS vended metrics; workload metrics are CloudWatch OTel Container Insights."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "EKS API and scheduler"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/EKS", "apiserver_request_total_5XX", "ClusterName", var.name, { stat = "Sum", label = "API server 5xx" }],
            ["AWS/EKS", "apiserver_request_total_429", "ClusterName", var.name, { stat = "Sum", label = "API server throttled requests" }],
            ["AWS/EKS", "scheduler_pending_pods", "ClusterName", var.name, { stat = "Sum", label = "Scheduler pending pods" }],
            ["AWS/EKS", "scheduler_pending_pods_UNSCHEDULABLE", "ClusterName", var.name, { stat = "Sum", label = "Unschedulable pods" }],
            ["AWS/EKS", "apiserver_request_duration_seconds_GET_P99", "ClusterName", var.name, { stat = "Average", label = "API GET p99 latency (seconds)" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "ALB targets and latency by stage"
          region  = var.aws_region
          period  = 60
          metrics = local.cloudwatch_target_group_metrics
        }
      },
      {
        type   = "chart"
        x      = 0
        y      = 8
        width  = 12
        height = 7
        properties = {
          view   = "line"
          title  = "Workload CPU and memory by namespace"
          region = var.aws_region
          data = {
            queries = [
              {
                id       = "cpu"
                type     = "cloudwatch-metrics"
                language = "PromQL"
                query    = "sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~\"${join("|", local.app_namespaces)}\",\"@resource.k8s.cluster.name\"=\"${var.name}\"}[5m]))"
                label    = "CPU cores"
                step     = 60
              },
              {
                id       = "memory"
                type     = "cloudwatch-metrics"
                language = "PromQL"
                query    = "sum by (namespace) (container_memory_working_set_bytes{namespace=~\"${join("|", local.app_namespaces)}\",\"@resource.k8s.cluster.name\"=\"${var.name}\"})"
                label    = "Memory working set bytes"
                step     = 60
              }
            ]
          }
        }
      },
      {
        type   = "chart"
        x      = 12
        y      = 8
        width  = 12
        height = 7
        properties = {
          view   = "line"
          title  = "HPA desired and current replicas"
          region = var.aws_region
          data = {
            queries = [
              {
                id       = "desired"
                type     = "cloudwatch-metrics"
                language = "PromQL"
                query    = "max by (namespace, horizontalpodautoscaler) (kube_horizontalpodautoscaler_status_desired_replicas{namespace=~\"${join("|", local.app_namespaces)}\",\"@resource.k8s.cluster.name\"=\"${var.name}\"})"
                label    = "Desired replicas"
                step     = 60
              },
              {
                id       = "current"
                type     = "cloudwatch-metrics"
                language = "PromQL"
                query    = "max by (namespace, horizontalpodautoscaler) (kube_horizontalpodautoscaler_status_current_replicas{namespace=~\"${join("|", local.app_namespaces)}\",\"@resource.k8s.cluster.name\"=\"${var.name}\"})"
                label    = "Current replicas"
                step     = 60
              }
            ]
          }
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 15
        width  = 24
        height = 4
        properties = {
          title = "EKS, HPA and target-health alarms"
          alarms = concat(
            [
              aws_cloudwatch_metric_alarm.eks_api_server_5xx.arn,
              aws_cloudwatch_metric_alarm.eks_unschedulable_pods.arn,
              aws_cloudwatch_metric_alarm.hpa_scaling_limited.arn,
              aws_cloudwatch_metric_alarm.failed_workload_pods.arn
            ],
            [for alarm in aws_cloudwatch_metric_alarm.alb_unhealthy_targets : alarm.arn]
          )
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 19
        width  = 24
        height = 7
        properties = {
          title  = "EKS control-plane logs (1-day retention)"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '/aws/eks/${var.name}/cluster' | fields @timestamp, @logStream, @message | sort @timestamp desc | limit 100"
        }
      }
    ]
  })
}
