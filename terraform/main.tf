# ============================================================
# LocalStay India — Complete AWS Infrastructure
# Deploy with: terraform init && terraform apply
# ============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── VARIABLES ──────────────────────────────────────────────
variable "aws_region" {
  default     = "ap-south-1"
  description = "AWS region (Mumbai)"
}

variable "project_name" {
  default     = "localstay"
  description = "Project prefix for all resources"
}

variable "alert_email" {
  description = "Email to receive booking notifications via SNS"
  type        = string
}

# ── S3 — Static Website Hosting ────────────────────────────
resource "aws_s3_bucket" "website" {
  bucket        = "${var.project_name}-website-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-website"
    Project = var.project_name
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.website.id
  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "website" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.website.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.website]
}

# S3 bucket for property images
resource "aws_s3_bucket" "images" {
  bucket        = "${var.project_name}-images-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-images"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "images" {
  bucket = aws_s3_bucket.images.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.images.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.images]
}

# ── CLOUDFRONT — CDN ───────────────────────────────────────
resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.project_name} website CDN"

  origin {
    domain_name = aws_s3_bucket_website_configuration.website.website_endpoint
    origin_id   = "S3-${aws_s3_bucket.website.bucket}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.website.bucket}"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  tags = { Project = var.project_name }
}

# ── DYNAMODB — Bookings Table ──────────────────────────────
resource "aws_dynamodb_table" "bookings" {
  name           = "${var.project_name}-bookings"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "booking_id"

  attribute {
    name = "booking_id"
    type = "S"
  }

  # GSI for querying by city
  global_secondary_index {
    name            = "city-index"
    hash_key        = "city"
    projection_type = "ALL"
  }

  attribute {
    name = "city"
    type = "S"
  }

  tags = {
    Name    = "${var.project_name}-bookings"
    Project = var.project_name
  }
}

# ── SNS — Email Notifications ──────────────────────────────
resource "aws_sns_topic" "booking_alerts" {
  name = "${var.project_name}-booking-alerts"
  tags = { Project = var.project_name }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.booking_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── IAM — Lambda Execution Role ────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          aws_dynamodb_table.bookings.arn,
          "${aws_dynamodb_table.bookings.arn}/index/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.booking_alerts.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── LAMBDA — Booking Handler ───────────────────────────────
data "archive_file" "booking_handler" {
  type        = "zip"
  source_file = "${path.module}/lambda/booking_handler.py"
  output_path = "${path.module}/lambda/booking_handler.zip"
}

resource "aws_lambda_function" "booking" {
  function_name    = "${var.project_name}-booking-handler"
  role             = aws_iam_role.lambda_role.arn
  handler          = "booking_handler.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.booking_handler.output_path
  source_code_hash = data.archive_file.booking_handler.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.booking_alerts.arn
      TABLE_NAME    = aws_dynamodb_table.bookings.name
    }
  }

  tags = { Project = var.project_name }
}

# LAMBDA — Get Bookings Handler
data "archive_file" "get_bookings" {
  type        = "zip"
  source_file = "${path.module}/lambda/get_bookings.py"
  output_path = "${path.module}/lambda/get_bookings.zip"
}

resource "aws_lambda_function" "get_bookings" {
  function_name    = "${var.project_name}-get-bookings"
  role             = aws_iam_role.lambda_role.arn
  handler          = "get_bookings.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.get_bookings.output_path
  source_code_hash = data.archive_file.get_bookings.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.bookings.name
    }
  }

  tags = { Project = var.project_name }
}

# ── API GATEWAY ────────────────────────────────────────────
resource "aws_api_gateway_rest_api" "localstay" {
  name        = "${var.project_name}-api"
  description = "LocalStay India booking API"

  tags = { Project = var.project_name }
}

# /booking resource
resource "aws_api_gateway_resource" "booking" {
  rest_api_id = aws_api_gateway_rest_api.localstay.id
  parent_id   = aws_api_gateway_rest_api.localstay.root_resource_id
  path_part   = "booking"
}

# POST /booking
resource "aws_api_gateway_method" "booking_post" {
  rest_api_id   = aws_api_gateway_rest_api.localstay.id
  resource_id   = aws_api_gateway_resource.booking.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "booking_post" {
  rest_api_id             = aws_api_gateway_rest_api.localstay.id
  resource_id             = aws_api_gateway_resource.booking.id
  http_method             = aws_api_gateway_method.booking_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.booking.invoke_arn
}

# OPTIONS /booking (CORS)
resource "aws_api_gateway_method" "booking_options" {
  rest_api_id   = aws_api_gateway_rest_api.localstay.id
  resource_id   = aws_api_gateway_resource.booking.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "booking_options" {
  rest_api_id = aws_api_gateway_rest_api.localstay.id
  resource_id = aws_api_gateway_resource.booking.id
  http_method = aws_api_gateway_method.booking_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "booking_options" {
  rest_api_id = aws_api_gateway_rest_api.localstay.id
  resource_id = aws_api_gateway_resource.booking.id
  http_method = aws_api_gateway_method.booking_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "booking_options" {
  rest_api_id = aws_api_gateway_rest_api.localstay.id
  resource_id = aws_api_gateway_resource.booking.id
  http_method = aws_api_gateway_method.booking_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.booking_options]
}

# /bookings resource (GET all)
resource "aws_api_gateway_resource" "bookings" {
  rest_api_id = aws_api_gateway_rest_api.localstay.id
  parent_id   = aws_api_gateway_rest_api.localstay.root_resource_id
  path_part   = "bookings"
}

resource "aws_api_gateway_method" "bookings_get" {
  rest_api_id   = aws_api_gateway_rest_api.localstay.id
  resource_id   = aws_api_gateway_resource.bookings.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "bookings_get" {
  rest_api_id             = aws_api_gateway_rest_api.localstay.id
  resource_id             = aws_api_gateway_resource.bookings.id
  http_method             = aws_api_gateway_method.bookings_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.get_bookings.invoke_arn
}

# API Deployment
resource "aws_api_gateway_deployment" "localstay" {
  rest_api_id = aws_api_gateway_rest_api.localstay.id

  depends_on = [
    aws_api_gateway_integration.booking_post,
    aws_api_gateway_integration.bookings_get,
    aws_api_gateway_integration.booking_options
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.localstay.id
  rest_api_id   = aws_api_gateway_rest_api.localstay.id
  stage_name    = "prod"

  tags = { Project = var.project_name }
}

# Lambda permissions for API Gateway
resource "aws_lambda_permission" "booking_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.booking.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.localstay.execution_arn}/*/*"
}

resource "aws_lambda_permission" "get_bookings_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_bookings.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.localstay.execution_arn}/*/*"
}

# ── CLOUDWATCH — Monitoring ─────────────────────────────────
resource "aws_cloudwatch_log_group" "booking_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.booking.function_name}"
  retention_in_days = 7
  tags              = { Project = var.project_name }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "60"
  statistic           = "Sum"
  threshold           = "3"
  alarm_description   = "Alert if Lambda booking errors exceed 3 in 1 minute"
  alarm_actions       = [aws_sns_topic.booking_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.booking.function_name
  }

  tags = { Project = var.project_name }
}

# ── OUTPUTS ────────────────────────────────────────────────
output "website_s3_url" {
  description = "S3 static website URL"
  value       = "http://${aws_s3_bucket_website_configuration.website.website_endpoint}"
}

output "cloudfront_url" {
  description = "CloudFront CDN URL (use this for production)"
  value       = "https://${aws_cloudfront_distribution.website.domain_name}"
}

output "api_gateway_url" {
  description = "API Gateway base URL — update in index.html"
  value       = "${aws_api_gateway_stage.prod.invoke_url}"
}

output "booking_endpoint" {
  description = "Full booking POST endpoint"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/booking"
}

output "get_bookings_endpoint" {
  description = "Full GET bookings endpoint"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/bookings"
}

output "dynamodb_table" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.bookings.name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for booking alerts"
  value       = aws_sns_topic.booking_alerts.arn
}

output "images_bucket" {
  description = "S3 bucket name for property images"
  value       = aws_s3_bucket.images.bucket
}
