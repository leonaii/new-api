import React, { useState, useEffect } from 'react';
import { Card, Input, Button, Typography, Space, Toast } from '@douyinfe/semi-ui';
import { IconLock } from '@douyinfe/semi-icons';
import ModelListAuthService from '../../services/modelListAuth';

const { Title, Text } = Typography;

const ModelListPasswordGuard = ({ children }) => {
  const [verified, setVerified] = useState(false);
  const [loading, setLoading] = useState(true);
  const [password, setPassword] = useState('');
  const [verifying, setVerifying] = useState(false);

  useEffect(() => {
    checkPasswordStatus();
  }, []);

  const checkPasswordStatus = async () => {
    try {
      const result = await ModelListAuthService.checkStatus();
      setVerified(result.verified);
    } catch (error) {
      console.error('检查验证状态失败:', error);
    } finally {
      setLoading(false);
    }
  };

  const handleVerify = async () => {
    if (!password) {
      Toast.error('请输入密码');
      return;
    }

    setVerifying(true);
    try {
      const result = await ModelListAuthService.verifyPassword(password);
      if (result.success) {
        Toast.success('验证成功');
        setVerified(true);
      } else {
        Toast.error(result.message || '验证失败');
      }
    } catch (error) {
      Toast.error('密码错误');
    } finally {
      setVerifying(false);
    }
  };

  const handleKeyPress = (e) => {
    if (e.key === 'Enter') {
      handleVerify();
    }
  };

  if (loading) {
    return (
      <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', minHeight: '400px' }}>
        <Card loading />
      </div>
    );
  }

  if (!verified) {
    return (
      <div style={{
        display: 'flex',
        justifyContent: 'center',
        alignItems: 'center',
        minHeight: '400px',
        padding: '20px'
      }}>
        <Card
          style={{
            maxWidth: '400px',
            width: '100%',
            textAlign: 'center'
          }}
        >
          <Space vertical align="center" spacing="large" style={{ width: '100%' }}>
            <IconLock size="extra-large" style={{ color: 'var(--semi-color-primary)' }} />
            <Title heading={3}>模型列表访问验证</Title>
            <Text type="secondary">此页面需要密码才能访问</Text>

            <Input
              type="password"
              placeholder="请输入访问密码"
              value={password}
              onChange={setPassword}
              onKeyPress={handleKeyPress}
              style={{ width: '100%' }}
              size="large"
            />

            <Button
              theme="solid"
              type="primary"
              size="large"
              loading={verifying}
              onClick={handleVerify}
              style={{ width: '100%' }}
            >
              验证
            </Button>
          </Space>
        </Card>
      </div>
    );
  }

  return children;
};

export default ModelListPasswordGuard;
