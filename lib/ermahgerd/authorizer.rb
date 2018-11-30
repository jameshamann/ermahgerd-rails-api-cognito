# frozen_string_literal: true

require 'json/jwt'

module Ermahgerd
  # The AWS Cognito access & id token is decoded and verified and then used in before controller hooks to determine
  # whether requests are from an authenticated source.
  module Authorizer
    extend ActiveSupport::Concern
    # rubocop:disable Metrics/BlockLength
    included do
      private

      # Your protected controllers should call this private method with a before-hook
      # ```
      # before_action :authorize_request!   # for every action in your controller
      # before_action :authorize_request!, only: [:create, :destroy, :update]   # include specific actions
      # ```
      # Raises Ermahgerd::Errors::Unauthorized if either the id or access token is:
      # 1. Missing from the headers
      # 2. Have been tampered with
      # 3. Cannot be decoded.
      # 4. If specific claims are missing or incorrect (e.g. :email, :aud, :iss, :sub)
      # 5. If the access token has expired
      # @private
      def authorize_request!
        verify_id_token!

        verify_access_token!

        raise Ermahgerd::Errors::SignatureExpired, 'Signature has expired' unless
          Time.zone.at(access_token[:exp] + Ermahgerd.configuration.access_token_leeway_seconds) > Time.zone.now
      end

      # Cached per request & decoded version of the access token.
      # Raises Ermahgerd::Errors::Unauthorized if the token has been tampered with or cannot be decoded.
      # @see https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-with-identity-providers.html#amazon-cognito-user-pools-using-the-access-token
      # @private
      def access_token
        @access_token ||= JSON::JWT.decode(authorization_from_header!, JSON::JWK::Set.new(jwk_set))
      rescue JSON::JWT::InvalidFormat, JSON::JWT::VerificationFailed, JSON::JWK::Set::KidNotFound
        Rails.logger.error 'Access token could not be decoded; possible key set issue or just an invalid token'
        raise Ermahgerd::Errors::Unauthorized, 'Invalid ACCESS token'
      end

      # Cached per request & decoded version of the id token.
      # Raises Ermahgerd::Errors::Unauthorized if the token has been tampered with or cannot be decoded.
      # @see https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-with-identity-providers.html#amazon-cognito-user-pools-using-the-id-token
      # @private
      def id_token
        @id_token ||= JSON::JWT.decode(identification_from_header!, JSON::JWK::Set.new(jwk_set))
      rescue JSON::JWT::InvalidFormat, JSON::JWT::VerificationFailed, JSON::JWK::Set::KidNotFound
        Rails.logger.error 'Token could not be decoded; possible key set issue or just an invalid token'
        raise Ermahgerd::Errors::Unauthorized, 'Invalid ID token'
      end

      # Helpers & Supporting Methods
      # ----------------------------------------------------------------------------------------------------------------

      # Extract the `Authorization` header and split out the token from the `Bearer ...` string.
      # Expecting key: `Authorization` (see Ermahgerd::HEADER_AUTHORIZATION)
      # Expecting value format: `Bearer some-sort.of-token.jibberish`
      # Raises Ermahgerd::Errors::Unauthorized if the token is missing.
      # @private
      def authorization_from_header!
        raw_token = request.headers[Ermahgerd::HEADER_AUTHORIZATION] || ''
        token = raw_token.split(' ')[-1]
        raise Ermahgerd::Errors::Unauthorized, 'ACCESS token is not found' if token.blank?

        token
      end

      # The key set from Cognito; should be in your secrets as `jwk_set`
      # https://cognito-idp.{region}.amazonaws.com/{userPoolId}/.well-known/jwks.json
      # NOTE ABOUT TESTING: we've created our own RSA private keys and public key sets
      def jwk_set
        return JSON.parse(File.read(Rails.root.join('config', 'test-jwk-set.json'))) if Rails.env.test?

        JSON.parse(Rails.application.credentials.dig(:jwk_set))
      end

      # Extract the `Identification` header value which is the id token.
      # Expecting key: `Identification` (see Ermahgerd::HEADER_IDENTIFICATION)
      # Expecting value format: `some-sort.of-token.jibberish` (NOTICE: NO Bearer declaration)
      # Raises Ermahgerd::Errors::Unauthorized if the token is missing.
      def identification_from_header!
        token = request.headers[Ermahgerd::HEADER_IDENTIFICATION] || ''
        raise Ermahgerd::Errors::Unauthorized, 'ID token is not found' if token.blank?

        token
      end

      # Raises Ermahgerd::Errors::ClaimsVerification if the ACCESS token is missing :jti claim.  Also raised
      # if the :iss claim is not what is configured in the app.
      # @see Ermahgerd.configuration.token_iss
      def verify_access_token!
        raise Ermahgerd::Errors::ClaimsVerification, 'ACCESS token claim is invalid' unless
          access_token[:iss] == Ermahgerd.configuration.token_iss &&
          access_token[:jti].present?
      end

      # Raises Ermahgerd::Errors::ClaimsVerification if the ID token is missing :email or :sub claims.  Also raised
      # if the :aud claim or :iss claim is not what is configured in the app.
      # @see Ermahgerd.configuration.token_aud
      # @see Ermahgerd.configuration.token_iss
      def verify_id_token!
        raise Ermahgerd::Errors::ClaimsVerification, 'ID token claim is invalid' unless
          id_token[:aud] == Ermahgerd.configuration.token_aud &&
          id_token[:email].present? &&
          id_token[:iss] == Ermahgerd.configuration.token_iss &&
          id_token[:sub].present?
      end
      # rubocop:enable Metrics/BlockLength
    end
  end
end