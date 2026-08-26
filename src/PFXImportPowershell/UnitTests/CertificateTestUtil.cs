// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portionas of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

namespace Microsoft.Management.Powershell.PFXImport.UnitTests
{
    using System;
    using System.Security.Cryptography;
    using System.Security.Cryptography.X509Certificates;

    public class CertificateTestUtil
    {
        /// <summary>
        /// Generates a self-signed test certificate
        /// </summary>
        /// <param name="subjectName">Subject name value</param>
        /// <param name="password">Password for encrypting the certificate</param>
        /// <returns>Password-protected PFX bytes</returns>
        public static byte[] CreateSelfSignedCertificatePfx(string subjectName, string password)
        {
            using (RSA rsa = RSA.Create(2048))
            {
                CertificateRequest request = new CertificateRequest(
                    "CN=" + subjectName,
                    rsa,
                    HashAlgorithmName.SHA256,
                    RSASignaturePadding.Pkcs1);

                return CreatePfx(request, password);
            }
        }

        /// <summary>
        /// Generates a self-signed ECC test certificate.
        /// </summary>
        public static byte[] CreateSelfSignedEccCertificatePfx(string subjectName, string password)
        {
            using (ECDsa ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP384))
            {
                CertificateRequest request = new CertificateRequest(
                    "CN=" + subjectName,
                    ecdsa,
                    HashAlgorithmName.SHA384);

                return CreatePfx(request, password);
            }
        }

        private static byte[] CreatePfx(CertificateRequest request, string password)
        {
            using (X509Certificate2 certificate = request.CreateSelfSigned(
                DateTimeOffset.UtcNow.AddMinutes(-1),
                DateTimeOffset.UtcNow.AddHours(1)))
            {
                return certificate.Export(X509ContentType.Pfx, password);
            }
        }
    }
}
