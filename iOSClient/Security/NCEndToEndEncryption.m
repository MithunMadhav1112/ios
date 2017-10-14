//
//  NCEndToEndEncryption.m
//  Nextcloud
//
//  Created by Marino Faggiana on 19/09/17.
//  Copyright © 2017 TWS. All rights reserved.
//
//  Author Marino Faggiana <m.faggiana@twsweb.it>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "NCEndToEndEncryption.h"
#import "NCBridgeSwift.h"
#import "CCUtility.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonKeyDerivation.h>

#import <openssl/x509.h>
#import <openssl/bio.h>
#import <openssl/err.h>
#import <openssl/pem.h>
#import <openssl/rsa.h>
#import <openssl/pkcs12.h>
#import <openssl/ssl.h>
#import <openssl/err.h>
#import <openssl/bn.h>

#define addName(field, value) X509_NAME_add_entry_by_txt(name, field, MBSTRING_ASC, (unsigned char *)value, -1, -1, 0); NSLog(@"%s: %s", field, value);

#define AES_KEY_LENGTH              16
#define AES_IVEC_LENGTH             16
#define AES_GCM_TAG_LENGTH          16

#define IV_DELIMITER_ENCODED        @"fA==" // "|" base64 encoded
#define PBKDF2_INTERACTION_COUNT    1024
#define PBKDF2_KEY_LENGTH           256
#define PBKDF2_SALT                 @"$4$YmBjm3hk$Qb74D5IUYwghUmzsMqeNFx5z0/8$"

#define fileNameCertificate         @"e2e_cert.pem"
#define fileNameCSR                 @"e2e_csr.pem"
#define fileNamePrivateKey          @"e2e_privateKey.pem"

@implementation NCEndToEndEncryption

//Singleton
+ (id)sharedManager {
    static NCEndToEndEncryption *NCEndToEndEncryption = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NCEndToEndEncryption = [self new];
    });
    return NCEndToEndEncryption;
}

#
#pragma mark - Generate Certificate X509 - CSR - Private Key
#

- (BOOL)generateCertificateX509WithUserID:(NSString *)userID directoryUser:(NSString *)directoryUser
{
    OPENSSL_init_ssl(0, NULL);
    OPENSSL_init_crypto(0, NULL);
    
    X509 *x509;
    x509 = X509_new();
    
    EVP_PKEY *pkey;
    NSError *keyError;
    pkey = [self generateRSAKey:&keyError];
    if (keyError) {
        return NO;
    }

    X509_set_pubkey(x509, pkey);
    EVP_PKEY_free(pkey);
    
    // Set Serial Number
    ASN1_INTEGER_set(X509_get_serialNumber(x509), 123);
    
    // Set Valididity Date Range
    long notBefore = [[NSDate date] timeIntervalSinceDate:[NSDate date]];
    long notAfter = [[[NSDate date] dateByAddingTimeInterval:60*60*24*365*10] timeIntervalSinceDate:[NSDate date]]; // 10 year
    X509_gmtime_adj((ASN1_TIME *)X509_get0_notBefore(x509), notBefore);
    X509_gmtime_adj((ASN1_TIME *)X509_get0_notAfter(x509), notAfter);
    
    X509_NAME *name = X509_get_subject_name(x509);
    
    // Now to add the subject name fields to the certificate
    // I use a macro here to make it cleaner.
    
    const unsigned char *cUserID = (const unsigned char *) [userID cStringUsingEncoding:NSUTF8StringEncoding];

    // Common Name = UserID.
    addName("CN", cUserID);
    
    // The organizational unit for the cert. Usually this is a department.
    addName("OU", "Certificate Authority");
    
    // The organization of the cert.
    addName("O",  "Nextcloud");
    
    // The city of the organization.
    addName("L",  "Vicenza");
    
    // The state/province of the organization.
    addName("S",  "Italy");
    
    // The country (ISO 3166) of the organization
    addName("C",  "IT");
    
    X509_set_issuer_name(x509, name);
    
    /*
     for (SANObject * san in self.options.sans) {
     if (!san.value || san.value.length <= 0) {
     continue;
     }
     
     NSString * prefix = san.type == SANObjectTypeIP ? @"IP:" : @"DNS:";
     NSString * value = [NSString stringWithFormat:@"%@%@", prefix, san.value];
     NSLog(@"Add subjectAltName %@", value);
     
     X509_EXTENSION * extension = NULL;
     ASN1_STRING * asnValue = ASN1_STRING_new();
     ASN1_STRING_set(asnValue, (const unsigned char *)[value UTF8String], (int)value.length);
     X509_EXTENSION_create_by_NID(&extension, NID_subject_alt_name, 0, asnValue);
     X509_add_ext(x509, extension, -1);
     }
     */
    
    // Specify the encryption algorithm of the signature.
    // SHA256 should suit your needs.
    if (X509_sign(x509, pkey, EVP_sha256()) < 0) {
        return NO;
    }
    
    X509_print_fp(stdout, x509);
    
    // Save to disk
    [self savePEMWithCert:x509 key:pkey directoryUser:directoryUser];
    
    return YES;
}

- (EVP_PKEY *)generateRSAKey:(NSError **)error
{
    EVP_PKEY *pkey = EVP_PKEY_new();
    if (!pkey) {
        return NULL;
    }
    
    BIGNUM *bigNumber = BN_new();
    int exponent = RSA_F4;
    RSA *rsa = RSA_new();
    
    if (BN_set_word(bigNumber, exponent) < 0) {
        goto cleanup;
    }
    
    if (RSA_generate_key_ex(rsa, 2048, bigNumber, NULL) < 0) {
        goto cleanup;
    }
    
    if (!EVP_PKEY_set1_RSA(pkey, rsa)) {
        goto cleanup;
    }
    
cleanup:
    RSA_free(rsa);
    BN_free(bigNumber);
    
    return pkey;
}

- (BOOL)savePEMWithCert:(X509 *)x509 key:(EVP_PKEY *)pkey directoryUser:(NSString *)directoryUser
{
    FILE *f;
    
    // Certificate
    /*
    NSString *certificatePath = [NSString stringWithFormat:@"%@/%@", directoryUser, fileNameCertificate];
    f = fopen([certificatePath fileSystemRepresentation], "wb");
    if (PEM_write_X509(f, x509) < 0) {
        // Error writing to disk.
        fclose(f);
        return NO;
    }
    NSLog(@"Saved cert to %@", certificatePath);
    fclose(f);
    */
    
    // Here you write the private key (pkey) to disk. OpenSSL will encrypt the
    // file using the password and cipher you provide.
    //if (PEM_write_PrivateKey(f, pkey, EVP_des_ede3_cbc(), (unsigned char *)[password UTF8String], (int)password.length, NULL, NULL) < 0) {
    
    // PrivateKey
    NSString *privatekeyPath = [NSString stringWithFormat:@"%@/%@", directoryUser, fileNamePrivateKey];
    f = fopen([privatekeyPath fileSystemRepresentation], "wb");
    if (PEM_write_PrivateKey(f, pkey, NULL, NULL, 0, NULL, NULL) < 0) {
        // Error
        fclose(f);
        return NO;
    }
    NSLog(@"Saved privatekey to %@", privatekeyPath);
    fclose(f);
    
    // CSR Request sha256
    NSString *csrPath = [NSString stringWithFormat:@"%@/%@", directoryUser, fileNameCSR];
    f = fopen([csrPath fileSystemRepresentation], "wb");
    X509_REQ *certreq = X509_to_X509_REQ(x509, pkey, EVP_sha256());
    if (PEM_write_X509_REQ(f, certreq) < 0) {
        // Error
        fclose(f);
        return NO;
    }
    NSLog(@"Saved csr to %@", csrPath);
    fclose(f);
    
    return YES;
}

/*
- (BOOL)saveP12WithCert:(X509 *)x509 key:(EVP_PKEY *)pkey directoryUser:(NSString *)directoryUser finished:(void (^)(NSError *))finished
{
    //PKCS12 * p12 = PKCS12_create([password UTF8String], NULL, pkey, x509, NULL, 0, 0, PKCS12_DEFAULT_ITER, 1, NID_key_usage);
    PKCS12 *p12 = PKCS12_create(NULL, NULL, pkey, x509, NULL, 0, 0, PKCS12_DEFAULT_ITER, 1, NID_key_usage);
    
    NSString *path = [NSString stringWithFormat:@"%@/certificate.p12", directoryUser];
    
    FILE *f = fopen([path fileSystemRepresentation], "wb");
    
    if (i2d_PKCS12_fp(f, p12) != 1) {
        fclose(f);
        return NO;
    }
    NSLog(@"Saved p12 to %@", path);
    fclose(f);
    
    return YES;
}
*/

- (NSString *)createEndToEndPublicKey:(NSString *)userID directoryUser:(NSString *)directoryUser
{
    NSString *csr;
    NSError *error;

    // Create Certificate, if do not exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/%@", directoryUser, fileNameCSR]]) {
        
        if (![self generateCertificateX509WithUserID:userID directoryUser:directoryUser])
            return nil;
    }
    
    csr = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@/%@", directoryUser, fileNameCSR] encoding:NSUTF8StringEncoding error:&error];

    if (error)
        return nil;
    
    return csr;
}

- (NSString *)createEndToEndPrivateKey:(NSString *)userID directoryUser: (NSString *)directoryUser mnemonic:(NSString *)mnemonic
{
    NSMutableData *privateKeyCipherData;
    NSString *privateKeyCipher;

    // Create Certificate, if do not exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/%@", directoryUser, fileNamePrivateKey]]) {
        
        if (![self generateCertificateX509WithUserID:userID directoryUser:directoryUser])
            return nil;
    }
    
    NSMutableData *keyData = [NSMutableData dataWithLength:PBKDF2_KEY_LENGTH];
    NSData *saltData = [PBKDF2_SALT dataUsingEncoding:NSUTF8StringEncoding];
    
    CCKeyDerivationPBKDF(kCCPBKDF2, mnemonic.UTF8String, mnemonic.length, saltData.bytes, saltData.length, kCCPRFHmacAlgSHA1, PBKDF2_INTERACTION_COUNT, keyData.mutableBytes, keyData.length);
    
    NSData *initVectorData = [self generateIV:AES_IVEC_LENGTH];
    NSData *privateKeyData = [[NSFileManager defaultManager] contentsAtPath:[NSString stringWithFormat:@"%@/%@", directoryUser, fileNamePrivateKey]];

    BOOL result = [self aes256gcmEncrypt:privateKeyData cipherData:&privateKeyCipherData keyData:keyData initVectorData:initVectorData tagData:nil];

    if (result && privateKeyCipherData) {
        
        privateKeyCipher = [privateKeyCipherData base64EncodedStringWithOptions:0];
        NSString *initVector= [initVectorData base64EncodedStringWithOptions:0];
        privateKeyCipher = [NSString stringWithFormat:@"%@%@%@", privateKeyCipher, IV_DELIMITER_ENCODED, initVector];
        
    } else {
        
        return nil;
    }
    
    return privateKeyCipher;
}

- (void)removeCSRToDisk:(NSString *)directoryUser
{
    [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@", directoryUser, fileNameCSR] error:nil];
}

- (void)removePrivateKeyToDisk:(NSString *)directoryUser
{
    [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/%@", directoryUser, fileNamePrivateKey] error:nil];
}

#
#pragma mark - Encrypt/Decrypt AES/GCM/NoPadding as cipher (128 bit key size)
#

- (void)encryptMetadata:(tableMetadata *)metadata activeUrl:(NSString *)activeUrl
{
    NSMutableData *cipherData;
    NSData *tagData;
    NSString* authenticationTag;

    NSData *plainData = [[NSFileManager defaultManager] contentsAtPath:[NSString stringWithFormat:@"%@/%@", activeUrl, metadata.fileID]];
    NSData *keyData = [[NSData alloc] initWithBase64EncodedString:@"WANM0gRv+DhaexIsI0T3Lg==" options:0];
    NSData *initVectorData = [[NSData alloc] initWithBase64EncodedString:@"gKm3n+mJzeY26q4OfuZEqg==" options:0];
    
    BOOL result = [self aes256gcmEncrypt:plainData cipherData:&cipherData keyData:keyData initVectorData:initVectorData tagData:&tagData];
    
    if (cipherData != nil && result) {
        [cipherData writeToFile:[NSString stringWithFormat:@"%@/%@", activeUrl, @"encrypted.dms"] atomically:YES];
        authenticationTag = [tagData base64EncodedStringWithOptions:0];
    }
}

- (void)decryptMetadata:(tableMetadata *)metadata activeUrl:(NSString *)activeUrl
{
    NSMutableData *plainData;
    
    NSData *cipherData = [[NSFileManager defaultManager] contentsAtPath:[NSString stringWithFormat:@"%@/%@", activeUrl, metadata.fileID]];
    NSData *keyData = [[NSData alloc] initWithBase64EncodedString:@"WANM0gRv+DhaexIsI0T3Lg==" options:0];
    NSData *initVectorData = [[NSData alloc] initWithBase64EncodedString:@"gKm3n+mJzeY26q4OfuZEqg==" options:0];
    NSString *tag = @"PboI9tqHHX3QeAA22PIu4w==";
    
    BOOL result = [self aes256gcmDecrypt:cipherData plainData:&plainData keyData:keyData initVectorData:initVectorData tag:tag];
    
    if (plainData != nil && result) {
        [plainData writeToFile:[NSString stringWithFormat:@"%@/%@", activeUrl, @"decrypted"] atomically:YES];
    }
}

// encrypt plain data
- (BOOL)aes256gcmEncrypt:(NSData*)plainData cipherData:(NSMutableData **)cipherData keyData:(NSData *)keyData initVectorData:(NSData *)initVectorData tagData:(NSData **)tagData
{
    int status = 0;
    *cipherData = [NSMutableData dataWithLength:[plainData length]];
    
    // set up key
    unsigned char cKey[AES_KEY_LENGTH];
    bzero(cKey, sizeof(cKey));
    [keyData getBytes:cKey length:AES_KEY_LENGTH];
    
    // set up ivec
    unsigned char cIv[AES_IVEC_LENGTH];
    bzero(cIv, AES_IVEC_LENGTH);
    [initVectorData getBytes:cIv length:AES_IVEC_LENGTH];
    
    // set up to Encrypt AES 128 GCM
    int numberOfBytes = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex (ctx, EVP_aes_128_gcm(), NULL, NULL, NULL);
    
    // set the key and ivec
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, AES_IVEC_LENGTH, NULL);
    EVP_EncryptInit_ex (ctx, NULL, NULL, cKey, cIv);
    
    unsigned char * ctBytes = [*cipherData mutableBytes];
    EVP_EncryptUpdate (ctx, ctBytes, &numberOfBytes, [plainData bytes], (int)[plainData length]);
    status = EVP_EncryptFinal_ex (ctx, ctBytes+numberOfBytes, &numberOfBytes);
    
    if (status && tagData) {
        
        unsigned char cTag[AES_GCM_TAG_LENGTH];
        bzero(cTag, AES_GCM_TAG_LENGTH);
        
        status = EVP_CIPHER_CTX_ctrl (ctx, EVP_CTRL_GCM_GET_TAG, AES_GCM_TAG_LENGTH, cTag);
        *tagData = [NSData dataWithBytes:cTag length:AES_GCM_TAG_LENGTH];
    }
    
    EVP_CIPHER_CTX_free(ctx);
    return (status != 0); // OpenSSL uses 1 for success
}

// decrypt cipher data
- (BOOL)aes256gcmDecrypt:(NSData *)cipherData plainData:(NSMutableData **)plainData keyData:(NSData *)keyData initVectorData:(NSData *)initVectorData tag:(NSString *)tag
{    
    int status = 0;
    int numberOfBytes = 0;
    *plainData = [NSMutableData dataWithLength:[cipherData length]];
    
    // set up key
    unsigned char cKey[AES_KEY_LENGTH];
    bzero(cKey, sizeof(cKey));
    [keyData getBytes:cKey length:AES_KEY_LENGTH];
    
    // set up ivec
    unsigned char cIv[AES_IVEC_LENGTH];
    bzero(cIv, AES_IVEC_LENGTH);
    [initVectorData getBytes:cIv length:AES_IVEC_LENGTH];
    
    // set up tag
    //unsigned char cTag[AES_GCM_TAG_LENGTH];
    //bzero(cTag, AES_GCM_TAG_LENGTH);
    //[tagData getBytes:cTag length:AES_GCM_TAG_LENGTH];
    
    /* verify tag */
    NSData *authenticationTagData = [cipherData subdataWithRange:NSMakeRange([cipherData length] - AES_GCM_TAG_LENGTH, AES_GCM_TAG_LENGTH)];
    NSString *authenticationTag = [authenticationTagData base64EncodedStringWithOptions:0];
    
    if (![authenticationTag isEqualToString:tag])
        return NO;
    
    /* Create and initialise the context */
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    
    /* Initialise the decryption operation. */
    status = EVP_DecryptInit_ex (ctx, EVP_aes_128_gcm(), NULL, NULL, NULL);
    if (! status)
        return NO;
    
    /* Set IV length. Not necessary if this is 12 bytes (96 bits) */
    status = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, AES_IVEC_LENGTH, NULL);
    if (! status)
        return NO;
    
    /* Initialise key and IV */
    status = EVP_DecryptInit_ex (ctx, NULL, NULL, cKey, cIv);
    if (! status)
        return NO;
    
    /* Provide the message to be decrypted, and obtain the plaintext output. */
    unsigned char * ctBytes = [*plainData mutableBytes];
    status = EVP_DecryptUpdate (ctx, ctBytes, &numberOfBytes, [cipherData bytes], (int)[cipherData length]);
    if (! status)
        return NO;
    
    /* Set expected tag value. Works in OpenSSL 1.0.1d and later */
    //status = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, AES_GCM_TAG_LENGTH, cTag);
    //if (!status)
    //    return NO;
    
    /* Finalise the decryption. A positive return value indicates success, anything else is a failure - the plaintext is n trustworthy. */
    //status = EVP_EncryptFinal_ex (ctx, ctBytes+numberOfBytes, &numberOfBytes);
    //if (!status)
    //    return NO;
    
    // Without test Final
    EVP_DecryptFinal_ex (ctx, NULL, &numberOfBytes);
    EVP_CIPHER_CTX_free(ctx);
    
    return status; // OpenSSL uses 1 for success
}

#
#pragma mark - Utility
#

- (NSString *)createSHA512:(NSString *)string
{
    const char *cstr = [string cStringUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [NSData dataWithBytes:cstr length:string.length];
    uint8_t digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(data.bytes, (unsigned int)data.length, digest);
    NSMutableString* output = [NSMutableString  stringWithCapacity:CC_SHA512_DIGEST_LENGTH * 2];
    
    for(int i = 0; i < CC_SHA512_DIGEST_LENGTH; i++)
        [output appendFormat:@"%02x", digest[i]];
    return output;
}

- (NSData *)generateIV:(int)ivLength
{
    NSMutableData  *ivData = [NSMutableData dataWithLength:ivLength];
    (void)SecRandomCopyBytes(kSecRandomDefault, ivLength, ivData.mutableBytes);
    
    return ivData;
}

@end