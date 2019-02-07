.PHONY: all clean build packer upload

VERSION = $(shell git describe --tags --candidates=1)
SHELL = /bin/bash -o pipefail
PACKER_FILES = $(exec find packer/)

all: packer build

# Remove any built cloudformation templates and packer output
clean:
	-rm -f build/*
	-rm packer.output

# Check for specific environment variables
env-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

# -----------------------------------------
# Template creation

mappings-for-image: env-AWS_REGION env-IMAGE_ID
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { AMI: %s }\n" \
		"$(AWS_REGION)" $(IMAGE_ID) > build/mappings.yml

build: build/aws-stack.yml

build/aws-stack.yml: templates/aws-stack.yml build/mappings.yml
	awk '{if($$0=="  # build/mappings.yml"){system("grep -v Mappings: build/mappings.yml")}else{print}}' templates/aws-stack.yml \
		| sed "s/%v/$(VERSION)/" > build/aws-stack.yml

# -----------------------------------------
# AMI creation with Packer

# Use packer to create an AMI
packer: packer.output env-AWS_REGION
	mkdir -p build/
	printf "Mappings:\n  AWSRegion2AMI:\n    %s: { AMI: %s }\n" \
		"$(AWS_REGION)" $$(grep -Eo "$(AWS_REGION): (ami-.+)" packer.output | cut -d' ' -f2) > build/mappings.yml

# Use packer to create an AMI and write the output to packer.output
packer.output: $(PACKER_FILES)
	docker run \
		-e AWS_DEFAULT_REGION  \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e PACKER_LOG \
		-v ${HOME}/.aws:/root/.aws \
		-v "$(PWD):/src" \
		--rm \
		-w /src/packer \
		hashicorp/packer:1.0.4 build buildkite-ami.json | tee packer.output

# -----------------------------------------
# Cloudformation helpers

TEMPLATE = aws-stack.yml

config.json:
	cp config.json.example config.json

create-stack: build/aws-stack.yml env-STACK_NAME
	aws cloudformation create-stack \
		--output text \
		--stack-name $(STACK_NAME) \
		--disable-rollback \
		--template-body "file://$(PWD)/build/aws-stack.yml" \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
		--parameters "$$(cat config.json)"

update-stack: build/aws-stack.yml env-STACK_NAME
	aws cloudformation update-stack \
		--output text \
		--stack-name $(STACK_NAME) \
		--template-body "file://$(PWD)/build/aws-stack.yml" \
		--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
		--parameters "$$(cat config.json)"

# -----------------------------------------
# Other

validate: build/aws-stack.yml
	aws cloudformation validate-template \
		--output text \
		--template-body "file://$(PWD)/build/aws-stack.yml"

generate-toc:
	docker run -it --rm -v "$(PWD):/app" node:slim bash \
		-c "npm install -g markdown-toc && cd /app && markdown-toc -i README.md"

# -----------------------------------------
# Lambda management

LAMBDA_S3_BUCKET := buildkite-aws-stack-lox
LAMBDA_S3_BUCKET_PATH := /

ec2-agent-scaler.zip: lambdas/ec2-agent-scaler/handler
	zip -9 -v -j $@ "$<"

lambdas/ec2-agent-scaler/handler: lambdas/ec2-agent-scaler/main.go
	docker run \
		--volume go-module-cache:/go/pkg/mod \
		--volume $(PWD):/code \
		--workdir /code \
		--rm golang:1.11 \
		go build -ldflags="$(FLAGS)" -o ./lambdas/ec2-agent-scaler/handler ./lambdas/ec2-agent-scaler
	chmod +x lambdas/ec2-agent-scaler/handler

lambda-sync: ec2-agent-scaler.zip
	aws s3 sync \
		--acl public-read \
		--exclude '*' --include '*.zip' \
		. s3://$(LAMBDA_S3_BUCKET)$(LAMBDA_S3_BUCKET_PATH)

lambda-versions:
	aws s3api head-object \
		--bucket ${LAMBDA_S3_BUCKET} \
		--key ec2-agent-scaler.zip --query "VersionId" --output text
