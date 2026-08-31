locals {
  repos = ["markets", "execution"]
}

resource "aws_ecr_repository" "app" {
  for_each = toset(local.repos)

  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a git SHA tag must never point at two builds

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Images are tagged by git SHA and nothing else, so "untagged" here means a layer
# set no manifest references any more — safe to expire quickly. Tagged images are
# kept deep enough to roll back several deploys.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent builds"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}
