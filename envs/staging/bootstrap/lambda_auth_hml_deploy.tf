# HML Lambda permissions are limited to the Terraform resources in the reviewed initial plan.
# Updates are allowed only for the exact HML function; role pass/manage permissions are bounded
# again by the shared policy using the deployment role's exact principal ARN.

data "aws_iam_policy_document" "lambda_auth_hml_deploy_service" {
  statement {
    sid       = "CreateBoundedLambdaExecutionRole"
    actions   = ["iam:CreateRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}lambda-auth-hml-execution"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values = [
        "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-boundary"
      ]
    }
  }

  statement {
    sid = "ManageLambdaExecutionRole"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}lambda-auth-hml-execution"]
  }

  statement {
    sid       = "PassOnlyLambdaAuthExecutionRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}lambda-auth-hml-execution"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid       = "CreateTaggedLambdaAuthSigningKey"
    actions   = ["kms:CreateKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Name"
      values   = ["auto-shop-hml-lambda-auth-jwt-signing"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Component"
      values   = ["lambda-auth"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["auto-shop-system"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Purpose"
      values   = ["rs256-signing"]
    }
  }

  statement {
    sid       = "ListKmsAliases"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }

  statement {
    sid       = "CreateOnlyLambdaAuthSigningAlias"
    actions   = ["kms:CreateAlias"]
    resources = ["arn:${local.partition}:kms:${var.aws_region}:${local.account_id}:alias/auto-shop/hml/lambda-auth/jwt-signing"]
  }

  statement {
    sid       = "CreateSigningAliasOnlyOnTaggedKey"
    actions   = ["kms:CreateAlias"]
    resources = ["arn:${local.partition}:kms:${var.aws_region}:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = ["auto-shop-hml-lambda-auth-jwt-signing"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Component"
      values   = ["lambda-auth"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["auto-shop-system"]
    }
  }

  statement {
    sid = "ManageTaggedLambdaAuthSigningKey"
    actions = [
      "kms:DescribeKey",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:EnableKey",
      "kms:EnableKeyRotation",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
      "kms:PutKeyPolicy",
      "kms:TagResource",
      "kms:UntagResource",
    ]
    resources = ["arn:${local.partition}:kms:${var.aws_region}:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = ["auto-shop-hml-lambda-auth-jwt-signing"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Component"
      values   = ["lambda-auth"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["auto-shop-system"]
    }
  }

  statement {
    sid       = "UseSigningKeyOnlyThroughParameterStore"
    actions   = ["kms:Decrypt", "kms:Encrypt"]
    resources = ["arn:${local.partition}:kms:${var.aws_region}:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/auto-shop/hml/lambda-auth/jwt-signing"]
    }
  }

  statement {
    sid = "ManageOnlyLambdaAuthHmlFunction"
    actions = [
      "lambda:CreateFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:ListVersionsByFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
    ]
    resources = ["arn:${local.partition}:lambda:${var.aws_region}:${local.account_id}:function:lambda-auth-hml"]
  }

  statement {
    sid       = "TagOnlyLambdaAuthHmlFunction"
    actions   = ["lambda:ListTags", "lambda:TagResource", "lambda:UntagResource"]
    resources = ["arn:${local.partition}:lambda:${var.aws_region}:${local.account_id}:function:lambda-auth-hml"]
  }

  statement {
    sid       = "ManageOnlyLambdaAuthHmlLogGroup"
    actions   = ["logs:CreateLogGroup", "logs:PutRetentionPolicy", "logs:TagLogGroup"]
    resources = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/lambda-auth-hml:*"]
  }

  statement {
    sid       = "DescribeLogGroupsForTerraformRefresh"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "TagOnlyLambdaAuthHmlLogGroup"
    actions   = ["logs:ListTagsForResource", "logs:TagResource", "logs:UntagResource"]
    resources = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/lambda-auth-hml:*"]
  }

  statement {
    sid       = "DescribeSsmParametersForTerraformRefresh"
    actions   = ["ssm:DescribeActivations", "ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid = "PublishOnlyLambdaAuthHmlFunctionArn"
    actions = [
      "ssm:AddTagsToResource",
      "ssm:GetParameter",
      "ssm:ListTagsForResource",
      "ssm:PutParameter",
      "ssm:RemoveTagsFromResource",
    ]
    resources = ["arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/auto-shop/staging/auth/customer-token/function-arn/hml"]
  }
}

resource "aws_iam_role_policy" "lambda_auth_hml_deploy_service" {
  name   = "lambda-auth-hml-deployment"
  role   = aws_iam_role.lambda_auth_hml_deploy.name
  policy = data.aws_iam_policy_document.lambda_auth_hml_deploy_service.json
}

