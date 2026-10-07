# Access logs for the public ALB, so a question like "who reads /v1/integrations?" has an answer.
# markets-service logs a user agent only on order submissions and cancels, never on reads, and
# nothing sits in front of the ALB, so until this nothing recorded a request path or a client.
# Standard ALB access logs: one gzipped line per request (time, client ip:port, path, user agent,
# status, latencies), delivered by the regional ELB service account, kept 30 days.

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = { Name = "${var.name}-alb-logs" }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-30d"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

# The regional ELB service account writes the logs; nothing else may write, and reads stay with the
# account's own principals.
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ALBAccessLogDelivery"
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    }]
  })
}
