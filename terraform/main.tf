terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "< 5.83.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  project_name = "githublamda"
  app_name     = "python"
  runtime      = "python3.11"
  handler      = "app.main.handler"
}

resource "aws_iam_role" "lambda_exec" {
  name = "${local.project_name}-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${local.project_name}-${local.app_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "app" {
  function_name = "${local.project_name}-${local.app_name}"
  role          = aws_iam_role.lambda_exec.arn
  runtime       = local.runtime
  handler       = local.handler
  filename      = "${path.module}/lambda_package.zip"
  timeout       = 30
  memory_size   = 512

  environment {
    variables = {
      APP_ENV = "production"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda_log_group
  ]
}

resource "aws_lambda_function_url" "app_url" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = "NONE"

  cors {
    allow_credentials = false
    allow_origins     = ["*"]
    allow_methods     = ["*"]
    allow_headers     = ["*"]
    max_age           = 86400
  }
}

output "lambda_function_name" {
  value = aws_lambda_function.app.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.app.arn
}

output "lambda_function_url" {
  value = aws_lambda_function_url.app_url.function_url
}

output "lambda_log_group" {
  value = aws_cloudwatch_log_group.lambda_log_group.name
}