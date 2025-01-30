provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "source_bucket" {
  bucket = "nagtr-source-bucket"
  acl    = "private"
}

resource "aws_efs_file_system" "efs_storage" {
  creation_token = "efs-storage"
}

resource "aws_efs_mount_target" "efs_mount" {
  file_system_id  = aws_efs_file_system.efs_storage.id
  subnet_id       = "subnet-12345678"  # Replace with subnet ID
  security_groups = ["sg-12345678"]  # Replace with  security group ID
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

resource "aws_iam_policy" "lambda_s3_efs_policy" {
  name        = "lambda_s3_efs_policy"
  description = "Policy for Lambda to access S3 and EFS"
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
        Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Effect   = "Allow"
        Resource = aws_efs_file_system.efs_storage.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_efs_policy.arn
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
        
        efs_path = os.environ['EFS_MOUNT_PATH']
        local_file_path = f"{efs_path}/{source_key}"
        
        try:
            s3.download_file(source_bucket, source_key, local_file_path)
            print(f"File {source_key} moved from {source_bucket} to EFS at {local_file_path}")
        except Exception as e:
            print(f"Error moving file: {str(e)}")
            raise e
    
    return {
        'statusCode': 200,
        'body': json.dumps('File transfer to EFS successful!')
    }
EOT
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "file_transfer" {
  function_name    = "s3_to_efs_transfer"
  role            = aws_iam_role.lambda_exec.arn
  runtime        = "python3.8"
  handler        = "lambda_function.lambda_handler"
  filename       = data.archive_file.lambda_package.output_path
  file_system_config {
    arn             = aws_efs_file_system.efs_storage.arn
    local_mount_path = "/mnt/efs"
  }
  environment {
    variables = {
      EFS_MOUNT_PATH = "/mnt/efs"
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
