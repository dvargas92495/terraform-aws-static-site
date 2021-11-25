output "deploy-id" {
  description = "The AWS Access Key ID for the IAM deployment user."
  value       = aws_iam_access_key.deploy[0].id
}

output "deploy-secret" {
  description = "The AWS Secret Key for the IAM deployment user."
  value       = aws_iam_access_key.deploy[0].secret
}

output "bucket-name" {
  description = "The name of the main S3 bucket."
  value       = aws_s3_bucket.main.bucket
}

output "route53_zone_id" {
  description = "The zone id of the given route53 domain"
  value       = data.aws_route53_zone.zone[local.zone_domain_names[local.primary_domain]].zone_id
}

output "cloudfront_arn" {
  description = "The cloudfront arn of the main distribution"
  value       = aws_cloudfront_distribution.cdn[0].arn
}

output "cloudfront_distribution_id" {
  description = "The Distribution Id of the main Cloudfront Distribution"
  value       = aws_cloudfront_distribution.cdn[0].id
}
