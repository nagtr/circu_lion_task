terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region  = "us-east-1"
  profile = "default"
}

resource "aws_instance" "testing_server" {
  ami           = "ami-0c614dee691cbbf37"
  instance_type = "t2.micro"

  tags = {
    Name = "nagtrExample"
  }
}
