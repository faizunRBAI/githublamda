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

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "githublamda"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "python_version" {
  description = "Python runtime version"
  type        = string
  default     = "python3.11"
}

variable "lambda_handler" {
  description = "Lambda handler"
  type        = string
  default     = "app.main.handler"
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment zip"
  type        = string
  default     = "lambda_function.zip"
}

variable "environment_variables" {
  description = "Environment variables for Lambda"
  type        = map(string)
  default     = {}
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "lambda_memory_size" {
  description = "Lambda function memory size in MB"
  type        = number
  default     = 512
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec-role"

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

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-function"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

locals {
  dummy_zip = "${path.module}/dummy_lambda.zip"
}

resource "null_resource" "create_dummy_zip" {
  triggers = {
    always = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
if [ ! -f "${local.dummy_zip}" ]; then
  echo 'handler = lambda event, context: {"statusCode": 200}' > /tmp/dummy_lambda_placeholder.py
  zip -j "${local.dummy_zip}" /tmp/dummy_lambda_placeholder.py
fi
EOT
  }
}

# Lambda Function
resource "aws_lambda_function" "app" {
  function_name = "${var.project_name}-function"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "app.main.handler"
  runtime       = "python${var.python_version}"
  filename      = fileexists(var.lambda_zip_path) ? var.lambda_zip_path : local.dummy_zip
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  source_code_hash = fileexists(var.lambda_zip_path) ? filebase64sha256(var.lambda_zip_path) : fileexists(local.dummy_zip) ? filebase64sha256(local.dummy_zip) : null

  environment {
    variables = merge(
      {
        APP_ENV      = "production"
        PORT         = "8000"
        MODULE_NAME  = "app.main"
        VARIABLE_NAME = "app"
      },
      var.environment_variables
    )
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda_logs,
    null_resource.create_dummy_zip,
  ]

  tags = {
    Project = var.project_name
  }
}

# Lambda Function URL (public HTTPS endpoint, no auth required)
resource "aws_lambda_function_url" "app_url" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = "NONE"

  cors {
    allow_credentials = false
    allow_origins     = ["*"]
    allow_methods     = ["*"]
    allow_headers     = ["*"]
    expose_headers    = ["*"]
    max_age           = 86400
  }
}

# API Gateway v2 (HTTP API) for Lambda
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["*"]
    allow_methods = ["*"]
    allow_origins = ["*"]
    max_age       = 86400
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "api_gw_logs" {
  name              = "/aws/api_gw/${var.project_name}-http-api"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      protocol       = "$context.protocol"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = {
    Project = var.project_name
  }
}