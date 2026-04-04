import 'dotenv/config';
import crypto from "crypto";
import express from "express";
import sql from "mssql";
import cors from "cors";
import axios from "axios";
import bcrypt from "bcryptjs";
import cron from "node-cron";
import jwt from "jsonwebtoken";
import { v4 as uuidv4 } from "uuid";

const app = express();
app.use(express.json());
app.use(cors());

// Azure SQL config
const azureConfig = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  server: process.env.DB_SERVER,
  database: process.env.DB_NAME,
  options: { encrypt: true }
};

// AES Encryption Setup
const ALGO = "aes-256-gcm";
const KEY = Buffer.from(process.env.ENCRYPTION_KEY, "hex"); // 32-byte hex

// JWT Setup
const JWT_SECRET = process.env.JWT_SECRET

// Server steup for testing
const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Server running on port ${port}`));

/*****************************************
 * HELPER FUNCTIONS
 *****************************************/
function encrypt(text) {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv(ALGO, KEY, iv);
  let encrypted = cipher.update(text, "utf8", "hex");
  encrypted += cipher.final("hex");
  const tag = cipher.getAuthTag().toString("hex");
  return { data: encrypted, iv: iv.toString("hex"), tag };
}

function decrypt({ data, iv, tag }) {
  const decipher = crypto.createDecipheriv(ALGO, KEY, Buffer.from(iv, "hex"));
  decipher.setAuthTag(Buffer.from(tag, "hex"));
  let decrypted = decipher.update(data, "hex", "utf8");
  decrypted += decipher.final("utf8");
  return decrypted;
}

async function hashPassword(plain) {
  const salt = await bcrypt.genSalt(10);
  return bcrypt.hash(plain, salt);
}

function verifyCron(req, res, next) {
  const secret = req.header("x-cron-secret");

  if (!secret || secret !== process.env.CRON_SECRET) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  next();
}

function toSqlDateTimeOffset(value) {
  const d = new Date(value);
  if (isNaN(d)) return null;

  // Truncate to milliseconds (Tedious-safe)
  d.setMilliseconds(Math.floor(d.getMilliseconds()));
  return d;
}

// This gets the date of 30 days ago and converts it to UNIX time, to be used in the simpleFin API call
function getUnixTime30DaysAgo() {
  const now = new Date();
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  return Math.floor(thirtyDaysAgo.getTime() / 1000);
}




/*****************************************
 * API Endpoints
 *****************************************/
app.get("/", async (req, res, next) => {

})

// Internal call from GitHub action to keep DB up to date
app.post("/internal/sync-simplefin-data", verifyCron, async (req, res, next) => {
  res.json({
    success: true,
    message: "Temporary response"
  });
});

// Register a new user
app.post("/register", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    const pool = await sql.connect(azureConfig);

    // Check if email already exists
    const existing = await pool.request()
      .input("email", sql.VarChar(255), email)
      .query(`SELECT id FROM Users WHERE email = @email`);

    if (existing.recordset.length > 0) {
      return res.status(409).json({ 
        success: false, 
        error: "Email already exists" 
      });
    }

    // Hash password and generate userID
    const hashed = await hashPassword(password);
    const id = uuidv4();

    // Insert new user into the Azure DB
    await pool.request()
      .input("id", sql.VarChar(50), id)
      .input("email", sql.VarChar(255), email)
      .input("passwordHash", sql.VarChar(255), hashed)
      .input("lastSimpleFinSync", sql.DateTime, null)
      .query(`
        INSERT INTO Users (
          id, email, passwordHash, lastSimpleFinSync
        )
        VALUES (@id, @email, @passwordHash, @lastSimpleFinSync)
      `);

    // Create a "Manual" transfer group by default for all users
    const tgid = uuidv4();
    await pool.request()
      .input("tgid", sql.VarChar(50), tgid)
      .input("userID", sql.VarChar(50), id)
      .input("name", sql.VarChar(255), "Manual")
      .query(`
        INSERT INTO TransferGroups (id, userID, name)
        VALUES (@tgid, @userID, @name)
      `);

    // Fetch the newly created user to return to the client
    const newUserResult = await pool.request()
      .input("id", sql.VarChar(50), id)
      .query(`
        SELECT 
          id, email, lastSimpleFinSync, createdAt, updatedAt
        FROM Users
        WHERE id = @id
      `);

    const newUser = newUserResult.recordset[0];

    // Generate JWT
    const token = jwt.sign({ id: newUser.id, email: newUser.email }, JWT_SECRET);

    res.json({ 
      success: true, 
      message: `New user registered`,
      token,
      user: newUser
    });

  } catch (err) {
    next(err);
  }
});

// Login an existing user with email/password
app.post("/login", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) return res.status(400).json({ success: false, error: "Missing fields" });
    
    const pool = await sql.connect(azureConfig);

    const result = await pool.request()
      .input("email", sql.VarChar(255), email)
      .query(`
        SELECT id, email, lastSimpleFinSync, simpleFinUsernameData, createdAt, updatedAt, passwordHash
        FROM Users
        WHERE email = @email
      `);

    if (result.recordset.length === 0) return res.json({ success: false, message: "Invalid email and password" });

    const user = result.recordset[0];
    const valid = await bcrypt.compare(password, user.passwordHash);

    // Remove sensitive fields before returning
    const simpleFinCredentialsSet = !!user.simpleFinUsernameData;
    delete user.simpleFinUsernameData;
    delete user.passwordHash;

    if (!valid) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    // Generate JWT
    const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET);

    return res.json({ 
      success: true, 
      token,
      user: { ...user, simpleFinCredentialsSet }
    });

  } catch (err) {
    next(err);
  }
});

// Connect the User's SimpleFin account
app.post("/connect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID, setupToken } = req.body;
    if (!userID || !setupToken) return res.status(400).json({ 
      success: false,
      message: "userID and setup token required",
      accounts: null
    });

    // Decode setup token into claim url
    let claimUrl;
    try {
      claimUrl = Buffer.from(setupToken, "base64").toString("utf-8");
    } catch {
      return res.status(400).json({
        success: false,
        message: "Invalid setup token format",
        accounts: null
      });
    }

    // Get access url
    let accessUrl;
    try {
      const claimResponse = await axios.post(claimUrl);
      accessUrl = claimResponse.data;

      if (!accessUrl || typeof accessUrl !== "string") {
        throw new Error("Invalid claim response");
      }
    } catch (err) {
      return res.status(400).json({
        success: false,
        message: "Failed to claim SimpleFIN token (may be expired or already used)",
        accounts: null
      });
    }

    // Fetch user's connected accounts from SimpleFIN
    let accounts;
    try {
      const accountResponse = await axios.get(`${accessUrl}/accounts`);
      accounts = accountResponse.data.accounts;
    } catch (err) {
      return res.status(500).json({
        success: false,
        message: "Failed to fetch accounts from SimpleFIN",
        accounts: null
      });
    }

    // Encrypt the access url before storing it in the database
    const accessEnc = encrypt(accessUrl);

    // Connect to Azure database
    const pool = await sql.connect(azureConfig);

    // Begin transaction
    const transaction = new sql.Transaction(pool);
    await transaction.begin();

    try {
      // Store access URL in Users table
      await new sql.Request(transaction)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("data", sql.VarChar(sql.MAX), accessEnc.data)
        .input("iv", sql.VarChar(32), accessEnc.iv)
        .input("tag", sql.VarChar(32), accessEnc.tag)
        .query(`
          UPDATE Users
          SET simpleFinAccessURLData = @data,
              simpleFinAccessURLIV = @iv,
              simpleFinAccessURLTag = @tag,
              updatedAt = SYSUTCDATETIME()
          WHERE id = @userID
        `);

      // Upsert accounts
      for (const account of accounts) {
        // Format the balance-date correctly
        const balanceDate = account["balance-date"]
          ? new Date(account["balance-date"] * 1000)
          : null;

        await new sql.Request(transaction)
          .input("id", sql.VarChar(100), account.id)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("name", sql.NVarChar(255), account.name)
          .input("accountBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
          .input("balanceDate", sql.DateTimeOffset, balanceDate)
          .query(`
            -- Update the account if it already exists
            UPDATE Accounts
            SET name = @name,
                accountBalance = @accountBalance,
                balanceDate = @balanceDate,
                updatedAt = SYSUTCDATETIME()
            WHERE id = @id AND userID = @userID;

            -- If the account did no exist, insert new account with type 'N/A'
            IF @@ROWCOUNT = 0
            BEGIN
              INSERT INTO Accounts (
                id, userID, name, accountBalance, balanceDate,
                accountType, createdAt, updatedAt
              )
              VALUES (
                @id, @userID, @name, @accountBalance, @balanceDate,
                'N/A', SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            END
          `);
      }

      await transaction.commit();

      // After all updates, fetch all accounts for this user
      const userAccounts = await pool.request()
          .input("userID", sql.UniqueIdentifier, userID)
          .query(`SELECT id, name, accountBalance, accountType, balanceDate, createdAt FROM Accounts WHERE userID = @userID`);

      return res.json({
        success: true,
        message: "SimpleFIN connected successfully",
        accounts: userAccounts.recordset
      });

    } catch (dbErr) {
      await transaction.rollback();
      throw dbErr;
    }


  } catch (err) {
    next(err);
  } 
});

// Disconnect a User's SimpleFIN account
app.post("/disconnect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID } = req.body;
    if (!userID) return res.status(400).json({ 
      success: false,
      message: "userID required"
    });

    // Connect to the Azure DB
    const pool = await sql.connect(azureConfig);

    // Query the DB to set the SimpleFIN data to NULL
    const result = await pool.request()
      .input("userID", sql.UniqueIdentifier, userID)
      .query(`
        UPDATE Users
        SET simpleFinAccessURLData = NULL,
            simpleFinAccessURLIV = NULL,
            simpleFinAccessURLTag = NULL,
            updatedAt = SYSUTCDATETIME()
        WHERE id = @userID
      `);
    
    // Ensure that the rows were edited
    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({
        success: false,
        message: "User not found or already disconnected"
      });
    }
    
    res.json({
      success: true,
      message: "SimpleFIN account disconnected"
    });

  } catch (err) {
    next(err);
  } 
});