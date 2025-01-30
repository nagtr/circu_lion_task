provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "source_bucket" {
  bucket = "my-source-bucket-terraform"
  acl    = "private"
}

resource "aws_s3_bucket" "destination_bucket" {
  bucket = "my-destination-bucket-terraform"
  acl    = "private"
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "lambda_s3_policy" {
  name        = "lambda_s3_policy"
  description = "Policy for Lambda to access S3"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.source_bucket.arn,
          "${aws_s3_bucket.source_bucket.arn}/*"
        ]
      },
      {
        Action   = ["s3:PutObject"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.destination_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

data "archive_file" "lambda_package" {
  type        = "zip"
  output_path = "lambda.zip"

  source {
    content  = <<EOT
import json
import boto3
import os

def lambda_handler(event, context):
    s3 = boto3.client('s3')
    
    for record in event['Records']:
        source_bucket = record['s3']['bucket']['name']
        source_key = record['s3']['object']['key']
        
        destination_bucket = os.environ['DESTINATION_BUCKET']
        
        try:
            copy_source = {'Bucket': source_bucket, 'Key': source_key}
            s3.copy_object(Bucket=destination_bucket, Key=source_key, CopySource=copy_source)
            print(f"File {source_key} copied from {source_bucket} to {destination_bucket}")
        except Exception as e:
            print(f"Error copying file: {str(e)}")
            raise e
    
    return {
        'statusCode': 200,
        'body': json.dumps('File transfer successful!')
    }
EOT
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "file_transfer" {
  function_name    = "s3_file_transfer"
  role            = aws_iam_role.lambda_exec.arn
  runtime        = "python3.8"
  handler        = "lambda_function.lambda_handler"
  filename       = data.archive_file.lambda_package.output_path
  environment {
    variables = {
      DESTINATION_BUCKET = aws_s3_bucket.destination_bucket.bucket
    }
  }
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_transfer.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.source_bucket.arn
}

resource "aws_s3_bucket_notification" "s3_event" {
  bucket = aws_s3_bucket.source_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.file_transfer.arn
    events              = ["s3:ObjectCreated:*"]
  }
}
