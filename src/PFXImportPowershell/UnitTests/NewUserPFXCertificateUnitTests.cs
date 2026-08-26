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
    using System.IO;
    using System.Linq;
    using System.Management.Automation;
    using System.Management.Automation.Runspaces;
    using System.Security;
    using System.Security.Cryptography;
    using System.Text;
    using Cmdlets;
    using Services.Api;
    using VisualStudio.TestTools.UnitTesting;

    [TestClass]
    public class NewUserPFXCertificateUnitTests
    {
        private const string TestUPN1 = "IWUser0@contoso.onmicrosoft.com";

        private string testPassword;

        private Runspace runspace;

        private SecureString securePassword;

        private PowerShell powershell;

        private RSACng passwordEncryptionKey;

        private string temporaryDirectory;

        private string testFilePath;

        private string testEccFilePath;

        private string publicKeyFilePath;

        public TestContext TestContext { get; set; }

        [TestInitialize]
        public void Initialize()
        {
            CreateTestPassword(out testPassword, out securePassword);

            InitialSessionState initialSessionState = InitialSessionState.CreateDefault();
            initialSessionState.Commands.Add(
                new SessionStateCmdletEntry(
                    "New-IntuneUserPfxCertificate", typeof(NewUserPFXCertificate), null));

            runspace = RunspaceFactory.CreateRunspace(initialSessionState);
            runspace.Open();

            powershell = PowerShell.Create();
            powershell.Runspace = runspace;

            temporaryDirectory = Path.Combine(
                TestContext.TestDeploymentDir,
                "PFXImportPSUnitTests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temporaryDirectory);
            testFilePath = Path.Combine(temporaryDirectory, "TestPFX.pfx");
            testEccFilePath = Path.Combine(temporaryDirectory, "TestEccPFX.pfx");
            publicKeyFilePath = Path.Combine(temporaryDirectory, "PfxPasswordEncryptionPublicKey.blob");

            File.WriteAllBytes(
                testFilePath,
                CertificateTestUtil.CreateSelfSignedCertificatePfx("TestCertSN", testPassword));

            CngKeyCreationParameters keyCreationParameters = new CngKeyCreationParameters();
            keyCreationParameters.Parameters.Add(
                new CngProperty(
                    "Length",
                    BitConverter.GetBytes(2048),
                    CngPropertyOptions.None));
            passwordEncryptionKey = new RSACng(CngKey.Create(
                CngAlgorithm.Rsa,
                null,
                keyCreationParameters));
            File.WriteAllBytes(
                publicKeyFilePath,
                passwordEncryptionKey.Key.Export(new CngKeyBlobFormat("RSAPUBLICBLOB")));
        }

        [TestCleanup]
        public void Cleanup()
        {
            if (powershell != null)
            {
                powershell.Dispose();
            }

            if (runspace != null)
            {
                runspace.Dispose();
            }

            if (securePassword != null)
            {
                securePassword.Dispose();
            }

            if (passwordEncryptionKey != null)
            {
                passwordEncryptionKey.Dispose();
            }

            if (!string.IsNullOrEmpty(temporaryDirectory) && Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, true);
            }
        }

        [TestMethod]
        public void TestEncryptPFXFile()
        {
            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testFilePath,
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.None,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);

            var pfxResults = powershell.Invoke<UserPFXCertificate>();

            Assert.AreEqual(pfxResults.Count, 1);

            UserPFXCertificate userPFXResult = pfxResults.First();

            Assert.IsTrue(string.IsNullOrEmpty(userPFXResult.KeyName));
            Assert.IsTrue(string.IsNullOrEmpty(userPFXResult.ProviderName));
            Assert.AreEqual(UserPfxKeyAlgorithm.Rsa, userPFXResult.KeyAlgorithm);
            Assert.AreNotEqual(userPFXResult.EncryptedPfxPassword, testPassword);
            Assert.AreEqual(userPFXResult.UserPrincipalName, TestUPN1);
            Assert.AreEqual(UserPfxPaddingScheme.OaepSha512, userPFXResult.PaddingScheme);
            Assert.AreEqual(userPFXResult.IntendedPurpose, UserPfxIntendedPurpose.SmimeEncryption);
            Assert.IsNotNull(userPFXResult.EncryptedPfxBlob);

            ValidatePasswordDecryptable(userPFXResult, testPassword, RSAEncryptionPadding.OaepSHA512);
        }

        [TestMethod]
        public void TestEncryptPFXFileOaepSha256()
        {
            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testFilePath,
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.OaepSha256,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);

            var pfxResults = powershell.Invoke<UserPFXCertificate>();

            Assert.AreEqual(pfxResults.Count, 1);

            UserPFXCertificate userPFXResult = pfxResults.First();

            Assert.AreEqual(userPFXResult.PaddingScheme, UserPfxPaddingScheme.OaepSha256);

            ValidatePasswordDecryptable(userPFXResult, testPassword, RSAEncryptionPadding.OaepSHA256);
        }

        [TestMethod]
        public void TestEncryptPFXFileOaepSha384()
        {
            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testFilePath,
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.OaepSha384,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);

            var pfxResults = powershell.Invoke<UserPFXCertificate>();

            Assert.AreEqual(pfxResults.Count, 1);

            UserPFXCertificate userPFXResult = pfxResults.First();

            Assert.AreEqual(userPFXResult.PaddingScheme, UserPfxPaddingScheme.OaepSha384);

            ValidatePasswordDecryptable(userPFXResult, testPassword, RSAEncryptionPadding.OaepSHA384);
        }

        [TestMethod]
        public void TestEncryptPFXFileOaepSha512()
        {
            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testFilePath,
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.OaepSha512,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);

            var pfxResults = powershell.Invoke<UserPFXCertificate>();

            Assert.AreEqual(pfxResults.Count, 1);

            UserPFXCertificate userPFXResult = pfxResults.First();

            Assert.AreEqual(userPFXResult.PaddingScheme, UserPfxPaddingScheme.OaepSha512);

            ValidatePasswordDecryptable(userPFXResult, testPassword, RSAEncryptionPadding.OaepSHA512);
        }

        [TestMethod]
        public void TestBadFileType()
        {
            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                @"TestCertificates\TestBadFile.txt",
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.None,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);
            try
            {
                _ = this.powershell.Invoke<UserPFXCertificate>();
                Assert.Fail("Expected an invalid PFX file to produce a terminating error.");
            }
            catch (Exception e)
            {
                Assert.IsTrue(e.Message.Contains("Could not Read Thumbprint"));
            }
        }

        [TestMethod]
        public void TestWrongPassword()
        {
            string incorrectPassword;
            SecureString badSecurePassword;
            CreateTestPassword(out incorrectPassword, out badSecurePassword);
            Assert.AreNotEqual(testPassword, incorrectPassword);

            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testFilePath,
                TestUPN1,
                badSecurePassword,
                UserPfxPaddingScheme.None,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);
            try
            {
                _ = powershell.Invoke<UserPFXCertificate>();
                Assert.Fail("Expected an invalid PFX password to produce a terminating error.");
            }
            catch (Exception e)
            {
                Assert.IsTrue(e.Message.Contains("Verify Password is Correct"));
            }
            finally
            {
                badSecurePassword.Dispose();
            }
        }

        [TestMethod]
        [ExpectedException(typeof(CmdletInvocationException))]
        public void TestMissingPublicKeyFile()
        {
            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testFilePath,
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.OaepSha512,
                UserPfxIntendedPurpose.SmimeEncryption,
                keyFilePath: Path.Combine(temporaryDirectory, "MissingPublicKey.blob"));

            powershell.Commands.AddCommand(encryptCommand);

            _ = powershell.Invoke<UserPFXCertificate>();
        }

        [TestMethod]
        public void TestEncryptPFXFileBase64String()
        {
            byte[] pfxData = File.ReadAllBytes(testFilePath);

            string base64String = Convert.ToBase64String(pfxData);

            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
            null,
            TestUPN1,
            securePassword,
            UserPfxPaddingScheme.None,
            UserPfxIntendedPurpose.SmimeEncryption,
            base64String);

            powershell.Commands.AddCommand(encryptCommand);

            var pfxResults = powershell.Invoke<UserPFXCertificate>();

            Assert.AreEqual(pfxResults.Count, 1);

            UserPFXCertificate userPFXResult = pfxResults.First();

            Assert.IsTrue(string.IsNullOrEmpty(userPFXResult.KeyName));
            Assert.IsTrue(string.IsNullOrEmpty(userPFXResult.ProviderName));
            Assert.AreEqual(UserPfxKeyAlgorithm.Rsa, userPFXResult.KeyAlgorithm);
            Assert.AreNotEqual(userPFXResult.EncryptedPfxPassword, testPassword);
            Assert.AreEqual(userPFXResult.UserPrincipalName, TestUPN1);
            Assert.AreEqual(UserPfxPaddingScheme.OaepSha512, userPFXResult.PaddingScheme);
            Assert.AreEqual(userPFXResult.IntendedPurpose, UserPfxIntendedPurpose.SmimeEncryption);
            Assert.IsNotNull(userPFXResult.EncryptedPfxBlob);

            ValidatePasswordDecryptable(userPFXResult, testPassword, RSAEncryptionPadding.OaepSHA512);
        }

        [TestMethod]
        public void TestEncryptEccPFXFile()
        {
            File.WriteAllBytes(
                testEccFilePath,
                CertificateTestUtil.CreateSelfSignedEccCertificatePfx("TestEccCertSN", testPassword));

            Command encryptCommand = GenerateSetUserPFXCertificatesCommand(
                testEccFilePath,
                TestUPN1,
                securePassword,
                UserPfxPaddingScheme.None,
                UserPfxIntendedPurpose.SmimeEncryption);

            powershell.Commands.AddCommand(encryptCommand);

            UserPFXCertificate userPFXResult = powershell.Invoke<UserPFXCertificate>().Single();

            Assert.AreEqual(UserPfxKeyAlgorithm.Ecc, userPFXResult.KeyAlgorithm);
        }

        private void ValidatePasswordDecryptable(UserPFXCertificate userPFXResult, string expectedPassword, RSAEncryptionPadding padding)
        {
            byte[] passwordBytes = Convert.FromBase64String(userPFXResult.EncryptedPfxPassword);
            byte[] unencryptedPassword = passwordEncryptionKey.Decrypt(passwordBytes, padding);
            string clearTextPassword = Encoding.ASCII.GetString(unencryptedPassword);

            Assert.AreEqual(clearTextPassword, expectedPassword);
        }

        private static void CreateTestPassword(out string password, out SecureString securePassword)
        {
            password = Guid.NewGuid().ToString("N");
            securePassword = new SecureString();
            foreach (char character in password)
            {
                securePassword.AppendChar(character);
            }
        }

        private Command GenerateSetUserPFXCertificatesCommand(
            string pathToPFXFile,
            string upn,
            SecureString pfxPassword,
            UserPfxPaddingScheme paddingScheme,
            UserPfxIntendedPurpose intendedPurpose,
            string base64Cert = null,
            string keyFilePath = null)
        {
            var encryptCommand = new Command("New-IntuneUserPfxCertificate");
            if(base64Cert == null)
            {
                encryptCommand.Parameters.Add("PathToPfxFile", pathToPFXFile);
            }else
            {
                encryptCommand.Parameters.Add("Base64EncodedPfx", base64Cert);
            }
            encryptCommand.Parameters.Add("UPN", upn);
            encryptCommand.Parameters.Add("PfxPassword", pfxPassword);
            encryptCommand.Parameters.Add("KeyFilePath", keyFilePath ?? publicKeyFilePath);
            encryptCommand.Parameters.Add("PaddingScheme", paddingScheme);
            encryptCommand.Parameters.Add("IntendedPurpose", intendedPurpose);

            return encryptCommand;
        }
    }
}