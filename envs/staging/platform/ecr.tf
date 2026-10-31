resource "aws_ecr_repository" "auto_shop_system" {
  # checkov:skip=CKV_AWS_163:Scan-on-push is configured by the registry-level rule below; this Checkov version only detects the deprecated repository-level setting.
  # checkov:skip=CKV_AWS_136:This staging repository uses AWS-managed AES256 encryption; changing its encryption would require replacement, and customer-managed key auditing is not required for app images.
  name                 = "auto-shop-system"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# BASIC scan-on-push does not add Inspector cost. The account currently has no
# registry scanning rules, so this rule scopes scanning to this application repo.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = aws_ecr_repository.auto_shop_system.name
      filter_type = "WILDCARD"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "auto_shop_system" {
  repository = aws_ecr_repository.auto_shop_system.name

  # Rollback uses the previously deployed digest. Keep immutable sha-* tagged images available;
  # only untagged copies are disposable after one day. Beyond the ten most recent commit-tagged
  # images, older ones are no longer reachable by any rollback target and are pruned too.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after one day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the ten most recent commit-tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
